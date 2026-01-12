// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Strings.sol";

interface FlatDirectoryFactoryInterface {
    function create() external returns (address);
}

interface IERC5018 {
    enum StorageMode {
        Uninitialized,
        OnChain,
        Blob
    }

    struct FileChunk {
        bytes name;
        uint256[] chunkIds;
    }

    // Large storage methods
    function write(bytes memory name, bytes memory data) external;

    function read(bytes memory name) external view returns (bytes memory, bool);

    // return (size, # of chunks)
    function size(bytes memory name) external view returns (uint256, uint256);

    function remove(bytes memory name) external returns (uint256);

    function countChunks(bytes memory name) external view returns (uint256);

    // Chunk-based large storage methods
    function writeChunkByCalldata(bytes memory name, uint256 chunkId, bytes memory data) external;

    function writeChunksByBlobs(bytes memory name, uint256[] memory chunkIds, uint256[] memory sizes) external payable;

    function readChunk(bytes memory name, uint256 chunkId) external view returns (bytes memory, bool);

    function readChunksPaged(bytes memory name, uint256 startChunkId, uint256 limit)
        external
        view
        returns (bytes[] memory chunks);

    function chunkSize(bytes memory name, uint256 chunkId) external view returns (uint256, bool);

    function removeChunk(bytes memory name, uint256 chunkId) external returns (bool);

    function truncate(bytes memory name, uint256 chunkId) external returns (uint256);

    function getChunkHash(bytes memory name, uint256 chunkId) external view returns (bytes32);

    function getChunkHashesBatch(FileChunk[] memory fileChunks) external view returns (bytes32[] memory);

    function getChunkCountsBatch(bytes[] memory names) external view returns (uint256[] memory);

    function getUploadInfo(bytes memory name)
        external
        view
        returns (StorageMode mode, uint256 chunkCount, uint256 storageCost);
}

contract SimpleW3Mail {
    using Strings for uint256;

    modifier isRegistered() {
        require(userInfos[msg.sender].fdContract != address(0), "Email is not register");
        _;
    }

    struct File {
        uint256 time;
        bytes uuid;
        bytes name;
    }

    struct Email {
        bool isEncryption;
        uint256 time;
        address from;
        address to;
        bytes uuid;
        bytes title;
        bytes fileUuid;
    }

    struct User {
        bytes32 publicKey;
        address fdContract;

        Email[] sentEmails;
        mapping(bytes => uint256) sentEmailIds;
        Email[] inboxEmails;
        mapping(bytes => uint256) inboxEmailIds;

        mapping(bytes => File) files;
    }

    string public constant defaultEmail =
        "Hi,<br><br>Congratulations for opening your first web3 email!<br><br>Advices For Security:<br>1. Do not trust the content or open links from unknown senders.<br>2. We will never ask for your private key.<br><br>W3Mail is in alpha.<br><br>Best regards,<br>W3Mail Team";

    FlatDirectoryFactoryInterface factory;

    mapping(address => User) userInfos;

    constructor(address _factory) {
        User storage user = userInfos[address(this)];
        user.publicKey = keccak256("official");
        factory = FlatDirectoryFactoryInterface(_factory);
    }

    receive() external payable {}

    function register(bytes32 publicKey) public {
        User storage user = userInfos[msg.sender];
        require(user.fdContract == address(0), "Address is registered");

        user.publicKey = publicKey;
        user.fdContract = factory.create();

        // add default email
        // create email
        Email memory dEmail;
        dEmail.time = block.timestamp;
        dEmail.from = address(this);
        dEmail.to = msg.sender;
        dEmail.uuid = "default-email";
        dEmail.title = "Welcome to W3Mail!";
        // add email
        user.inboxEmails.push(dEmail);
        user.inboxEmailIds["default-email"] = 1;
    }

    function sendEmail(
        address toAddress,
        bool isEncryption,
        bytes memory uuid,
        bytes memory title,
        bytes calldata encryptData,
        bytes memory fileUuid
    ) public isRegistered {
        User storage toInfo = userInfos[toAddress];
        require(!isEncryption || toInfo.fdContract != address(0), "Unregistered users can only send unencrypted emails");
        User storage fromInfo = userInfos[msg.sender];
        // create email
        Email memory email;
        email.isEncryption = isEncryption;
        email.time = block.timestamp;
        email.from = msg.sender;
        email.to = toAddress;
        email.uuid = uuid;
        email.title = title;
        email.fileUuid = fileUuid;

        // add email
        fromInfo.sentEmails.push(email);
        fromInfo.sentEmailIds[uuid] = fromInfo.sentEmails.length;
        toInfo.inboxEmails.push(email);
        toInfo.inboxEmailIds[uuid] = toInfo.inboxEmails.length;

        // write email
        IERC5018 fileContract = IERC5018(fromInfo.fdContract);
        fileContract.writeChunkByCalldata(getNewName(uuid, "message"), 0, encryptData);
    }

    function writeChunk(bytes memory uuid, bytes memory name, uint256 chunkId, bytes calldata data) public {
        User storage user = userInfos[msg.sender];
        if (user.files[uuid].time == 0) {
            // first add file
            user.files[uuid] = File(block.timestamp, uuid, name);
        }

        IERC5018 fileContract = IERC5018(user.fdContract);
        fileContract.writeChunkByCalldata(getNewName("file", uuid), chunkId, data);
    }

    function removeContent(address from, address fromFdContract, bytes memory uuid, bytes memory fileUuid) private {
        IERC5018 fileContract = IERC5018(fromFdContract);
        // remove mail
        fileContract.remove(getNewName(uuid, "message"));
        // remove file
        fileContract.remove(getNewName("file", fileUuid));
    }

    function removeSentEmail(bytes memory uuid) public {
        User storage info = userInfos[msg.sender];
        require(info.sentEmailIds[uuid] != 0, "Email does not exist");

        uint256 removeIndex = info.sentEmailIds[uuid] - 1;
        // remove content
        Email memory email = info.sentEmails[removeIndex];
        if (userInfos[email.to].inboxEmailIds[uuid] == 0) {
            // if inbox is delete
            removeContent(msg.sender, info.fdContract, uuid, email.fileUuid);
        }

        // remove info
        uint256 lastIndex = info.sentEmails.length - 1;
        if (lastIndex != removeIndex) {
            info.sentEmails[removeIndex] = info.sentEmails[lastIndex];
            info.sentEmailIds[info.sentEmails[lastIndex].uuid] = removeIndex + 1;
        }
        info.sentEmails.pop();
        delete info.sentEmailIds[uuid];
    }

    function removeInboxEmail(bytes memory uuid) public {
        User storage info = userInfos[msg.sender];
        require(info.inboxEmailIds[uuid] != 0, "Email does not exist");

        uint256 removeIndex = info.inboxEmailIds[uuid] - 1;
        // remove content
        Email memory email = info.inboxEmails[removeIndex];
        if (userInfos[email.from].sentEmailIds[uuid] == 0) {
            // if sent is delete
            removeContent(email.from, userInfos[email.from].fdContract, uuid, email.fileUuid);
        }

        // remove info
        uint256 lastIndex = info.inboxEmails.length - 1;
        if (lastIndex != removeIndex) {
            info.inboxEmails[removeIndex] = info.inboxEmails[lastIndex];
            info.inboxEmailIds[info.inboxEmails[lastIndex].uuid] = removeIndex + 1;
        }
        info.inboxEmails.pop();
        delete info.inboxEmailIds[uuid];
    }

    function removeEmails(uint256 types, bytes[] memory uuids) public {
        if (types == 1) {
            for (uint256 i; i < uuids.length; i++) {
                removeInboxEmail(uuids[i]);
            }
        } else {
            for (uint256 i; i < uuids.length; i++) {
                removeSentEmail(uuids[i]);
            }
        }
    }

    function getNewName(bytes memory dir, bytes memory name) public pure returns (bytes memory) {
        return abi.encodePacked(dir, "/", name);
    }

    function getInboxEmails()
        public
        view
        returns (
            bool[] memory isEncryptions,
            uint256[] memory times,
            address[] memory fromMails,
            address[] memory toMails,
            bytes[] memory uuids,
            bytes[] memory titles,
            bytes[] memory fileUuids,
            bytes[] memory fileNames
        )
    {
        User storage info = userInfos[msg.sender];
        uint256 length = info.inboxEmails.length;
        isEncryptions = new bool[](length);
        times = new uint256[](length);
        uuids = new bytes[](length);
        fromMails = new address[](length);
        toMails = new address[](length);
        titles = new bytes[](length);
        fileUuids = new bytes[](length);
        fileNames = new bytes[](length);
        for (uint256 i; i < length; i++) {
            isEncryptions[i] = info.inboxEmails[i].isEncryption;
            times[i] = info.inboxEmails[i].time;
            fromMails[i] = info.inboxEmails[i].from;
            toMails[i] = info.inboxEmails[i].to;
            uuids[i] = info.inboxEmails[i].uuid;
            titles[i] = info.inboxEmails[i].title;
            fileUuids[i] = info.inboxEmails[i].fileUuid;
            fileNames[i] = userInfos[fromMails[i]].files[fileUuids[i]].name;
        }
    }

    function getSentEmails()
        public
        view
        returns (
            bool[] memory isEncryptions,
            uint256[] memory times,
            address[] memory fromMails,
            address[] memory toMails,
            bytes[] memory uuids,
            bytes[] memory titles,
            bytes[] memory fileUuids,
            bytes[] memory fileNames
        )
    {
        User storage info = userInfos[msg.sender];
        uint256 length = info.sentEmails.length;
        isEncryptions = new bool[](length);
        times = new uint256[](length);
        uuids = new bytes[](length);
        fromMails = new address[](length);
        toMails = new address[](length);
        titles = new bytes[](length);
        fileUuids = new bytes[](length);
        fileNames = new bytes[](length);
        for (uint256 i; i < length; i++) {
            isEncryptions[i] = info.sentEmails[i].isEncryption;
            times[i] = info.sentEmails[i].time;
            fromMails[i] = info.sentEmails[i].from;
            toMails[i] = info.sentEmails[i].to;
            uuids[i] = info.sentEmails[i].uuid;
            titles[i] = info.sentEmails[i].title;
            fileUuids[i] = info.sentEmails[i].fileUuid;
            fileNames[i] = info.files[fileUuids[i]].name;
        }
    }

    function getEmailContent(address fromEmail, bytes memory uuid, uint256 chunkId)
        public
        view
        returns (bytes memory data)
    {
        if (fromEmail == address(this) && keccak256(uuid) == keccak256("default-email")) {
            return bytes(defaultEmail);
        }
        IERC5018 fileContract = IERC5018(getFlatDirectory(fromEmail));
        (data,) = fileContract.readChunk(getNewName(uuid, bytes("message")), chunkId);
    }

    function getFile(address fromEmail, bytes memory uuid, uint256 chunkId) public view returns (bytes memory data) {
        IERC5018 fileContract = IERC5018(getFlatDirectory(fromEmail));
        (data,) = fileContract.readChunk(getNewName("file", uuid), chunkId);
    }

    function countChunks(address fromEmail, bytes memory uuid) public view returns (uint256) {
        IERC5018 fileContract = IERC5018(getFlatDirectory(fromEmail));
        return fileContract.countChunks(getNewName("file", uuid));
    }

    function getPublicKey(address userAddress) public view returns (bytes32 publicKey) {
        return userInfos[userAddress].publicKey;
    }

    function getFlatDirectory(address userAddress) internal view returns (address) {
        return userInfos[userAddress].fdContract;
    }
}
