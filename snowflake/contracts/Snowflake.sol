pragma solidity ^0.4.24;

import "./zeppelin/ownership/Ownable.sol";
import "./zeppelin/token/ERC20/ERC20.sol";
import "./zeppelin/math/SafeMath.sol";

import "./libraries/uint8Set.sol";
import "./libraries/addressSet.sol";
import "./libraries/bytes32Set.sol";


interface ClientRaindrop {
    function getUserByAddress(address _address) external view returns (string userName);
}


contract Snowflake is Ownable {
    using SafeMath for uint;
    using uint8Set for uint8Set._uint8Set;
    using addressSet for addressSet._addressSet;
    using bytes32Set for bytes32Set._bytes32Set;

    // hydro token wrapper variable
    mapping (address => uint) public deposits;

    // token lookup mappings
    uint public nextTokenId = 1;
    mapping (uint => Identity) internal tokenDirectory;
    mapping (address => uint) public ownerToToken;

    // admin/contract variables
    address public clientRaindropAddress;
    address public hydroTokenAddress;

    addressSet._addressSet internal resolverWhitelist;
    uint public resolverWhitelistFee;

    // name and date of birth restriction variables
    string[6] nameOrder = ["prefix", "givenName", "middleName", "surname", "suffix", "preferredName"];
    bytes32Set._bytes32Set allowedNames;
    string[3] dateOrder = ["day", "month", "year"];
    bytes32Set._bytes32Set allowedDates;

    // identity structures
    struct Identity {
        address owner;
        string hydroId;
        mapping (uint8 => SnowflakeField) fields; // mapping of AllowedSnowflakeFields to SnowflakeFields
        uint8Set._uint8Set fieldsAttestedTo;
        mapping(address => Resolver) resolvers;
        addressSet._addressSet resolversFor; // optional, set of third-party resolvers
    }

    struct SnowflakeField {
        mapping (bytes32 => Entry) entries; // required, mapping of entry names to encrypted plaintext data.
        bytes32Set._bytes32Set entriesAttestedTo; // required, entry names that the user has attested to
    }

    struct Entry {
        string entryName;
        bytes32 saltedHash; // data should be encoded as: keccak256(abi.encodePacked(data, salt))
        uint blockNumber;
    }

    struct Resolver {
        uint withdrawAllowance; // optional, allows resolvers to programatically extract hydro from users
    }

    // field restriction variables
    enum AllowedSnowflakeFields { Name, DateOfBirth, Emails, PhoneNumbers, PhysicalAddresses }
    mapping (uint8 => bool) internal allowedFields;

    constructor () public {
        // initialize allowed snowflake fields
        allowedFields[uint8(AllowedSnowflakeFields.Name)] = true;
        allowedFields[uint8(AllowedSnowflakeFields.Emails)] = true;
        allowedFields[uint8(AllowedSnowflakeFields.PhoneNumbers)] = true;
        allowedFields[uint8(AllowedSnowflakeFields.PhysicalAddresses)] = true;

        // initialize allowed name entries
        for (uint i; i < nameOrder.length; i++) {
            allowedNames.insert(keccak256(abi.encodePacked(nameOrder[i])));
        }

        // initialize allowed date entries
        for (uint j; j < dateOrder.length; j++) {
            allowedDates.insert(keccak256(abi.encodePacked(dateOrder[j])));
        }
    }

    // enforces that the transaction sender has a token
    modifier _hasToken(address _address, bool check) {
        require(hasToken(_address) == check, "The transaction sender has not minted a Snowflake.");
        _;
    }

    // checks whether the given address has a token
    function hasToken(address _address) public view returns (bool) {
        return ownerToToken[_address] != 0;
    }

    // enforces that the given tokenId exists
    modifier _tokenExists(uint tokenId) {
        require(tokenExists(tokenId), "This token has not yet been minted.");
        _;
    }

    // checks whether the given tokenId exists
    function tokenExists(uint tokenId) public view returns (bool) {
        return tokenDirectory[tokenId].owner != address(0);
    }
    
    // wrapper to ownerToToken that throws if the address doesn't own a token
    function getTokenId(address _address) public view returns (uint tokenId) {
        require(hasToken(_address));
        return ownerToToken[_address];
    }

    // set the fee to become a resolver
    function setResolverWhitelistFee(uint fee) public onlyOwner {
        ERC20 hydro = ERC20(hydroTokenAddress);
        require(fee <= (hydro.totalSupply() / 100 / 10), "Fee is too high.");
        resolverWhitelistFee = fee;
    }

    // allows whitelisting of resolvers
    function whitelistResolver(address resolver) public {
        transferSnowflakeBalance(owner, resolverWhitelistFee);
        resolverWhitelist.insert(resolver);
        emit ResolverWhitelisted(resolver, msg.sender);
    }

    // set the raindrop and hydro token addresses
    function setAddresses(address clientRaindrop, address hydroToken) public onlyOwner {
        clientRaindropAddress = clientRaindrop;
        hydroTokenAddress = hydroToken;
    }

    // token minter
    function mintIdentityToken(bytes32[6] names, bytes32[3] dateOfBirth) public _hasToken(msg.sender, false)
        returns(uint tokenId)
    {
        ClientRaindrop clientRaindrop = ClientRaindrop(clientRaindropAddress);
        string memory _hydroId = clientRaindrop.getUserByAddress(msg.sender);

        uint newTokenId = nextTokenId++;
        Identity storage identity = tokenDirectory[newTokenId];

        identity.owner = msg.sender;
        identity.hydroId = _hydroId;

        SnowflakeField storage nameField = identity.fields[uint8(AllowedSnowflakeFields.Name)];
        for (uint i; i < names.length; i++) {
            if (names[i] == bytes32(0x0)) {
                continue;
            }
            nameField.entries[allowedNames.members[i]].entryName = nameOrder[i];
            nameField.entries[allowedNames.members[i]].saltedHash = names[i];
            nameField.entries[allowedNames.members[i]].blockNumber = block.number;
            nameField.entriesAttestedTo.insert(allowedNames.members[i]);
            // putting this here creates some unnecessary checks, but it catches the case when all elements are 0x0
            identity.fieldsAttestedTo.insert(uint8(AllowedSnowflakeFields.Name));
        }

        SnowflakeField storage dateField = identity.fields[uint8(AllowedSnowflakeFields.DateOfBirth)];
        for (uint j; j < dateOfBirth.length; j++) {
            if (dateOfBirth[j] == bytes32(0x0)) {
                continue;
            }
            dateField.entries[allowedDates.members[j]].entryName = dateOrder[j];
            dateField.entries[allowedDates.members[j]].saltedHash = dateOfBirth[j];
            dateField.entries[allowedDates.members[j]].blockNumber = block.number;
            dateField.entriesAttestedTo.insert(allowedDates.members[j]);
            // putting this here creates some unnecessary checks, but it catches the case when all elements are 0x0
            identity.fieldsAttestedTo.insert(uint8(AllowedSnowflakeFields.DateOfBirth));
        }

        ownerToToken[msg.sender] = newTokenId;
        emit SnowflakeMinted(newTokenId, msg.sender);
        return newTokenId;
    }

    // wrappers that allow easy access to modify resolvers
    function addResolvers(address[] resolvers, uint[] withdrawAllowances) public _hasToken(msg.sender, true) {
        require(resolvers.length == withdrawAllowances.length, "Malformed inputs.");

        Identity storage identity = tokenDirectory[ownerToToken[msg.sender]];

        for (uint i; i < resolvers.length; i++) {
            require(resolverWhitelist.contains(resolvers[i]), "The given resolver is not on the whitelist.");
            require(!identity.resolversFor.contains(resolvers[i]), "This snowflake has already set this resolver.");
            identity.resolversFor.insert(resolvers[i]);
            identity.resolvers[resolvers[i]].withdrawAllowance = withdrawAllowances[i];
        }

        emit ResolversAdded(ownerToToken[msg.sender], resolvers, withdrawAllowances);
    }

    function changeResolverAllowances(address[] resolvers, uint[] withdrawAllowances)
        public _hasToken(msg.sender, true)
    {
        require(resolvers.length == withdrawAllowances.length, "Malformed inputs.");

        Identity storage identity = tokenDirectory[ownerToToken[msg.sender]];

        for (uint i; i < resolvers.length; i++) {
            require(identity.resolversFor.contains(resolvers[i]), "This snowflake has not set this resolver");
            identity.resolvers[resolvers[i]].withdrawAllowance = withdrawAllowances[i];
        }

        emit ResolversAllowanceChanged(ownerToToken[msg.sender], resolvers, withdrawAllowances);
    }

    function removeResolvers(address[] resolvers) public _hasToken(msg.sender, true) {
        Identity storage identity = tokenDirectory[ownerToToken[msg.sender]];

        for (uint i; i < resolvers.length; i++) {
            require(identity.resolversFor.contains(resolvers[i]), "This snowflake has not set this resolver");
            identity.resolversFor.remove(resolvers[i]);
            delete identity.resolvers[resolvers[i]];
        }

        emit ResolversRemoved(ownerToToken[msg.sender], resolvers);
    }

    // add/remove field entries
    function addFieldEntry(uint8 field, string entry, bytes32 saltedHash) public _hasToken(msg.sender, true) {
        require(allowedFields[field], "Invalid field.");

        bytes32 entryLookup = keccak256(abi.encodePacked(entry));
        if (field == uint8(AllowedSnowflakeFields.Name)) {
            require(allowedNames.contains(entryLookup));
        }

        Identity storage identity = tokenDirectory[ownerToToken[msg.sender]];
        require(!identity.fields[field].entriesAttestedTo.contains(entryLookup), "Entry already exists");

        identity.fields[field].entriesAttestedTo.insert(entryLookup);
        identity.fields[field].entries[entryLookup].entryName = entry;
        identity.fields[field].entries[entryLookup].saltedHash = saltedHash;
        identity.fields[field].entries[entryLookup].blockNumber = block.number;

        identity.fieldsAttestedTo.insert(field);
    }

    function removeFieldEntry(uint8 field, string entry) public _hasToken(msg.sender, true) {
        require(allowedFields[field], "Invalid field.");

        bytes32 entryLookup = keccak256(abi.encodePacked(entry));

        Identity storage identity = tokenDirectory[ownerToToken[msg.sender]];
        require(identity.fields[field].entriesAttestedTo.contains(entryLookup), "Entry does not exist");

        identity.fields[field].entriesAttestedTo.remove(entryLookup);
        delete identity.fields[field].entries[entryLookup];
        if (identity.fields[field].entriesAttestedTo.length() == 0) {
            identity.fieldsAttestedTo.remove(field);
        }
    }

    // check resolver membership
    function hasResolver(uint tokenId, address resolver) public view _tokenExists(tokenId) returns (bool) {
        Identity storage identity = tokenDirectory[tokenId];
        return identity.resolversFor.contains(resolver);
    }

    // functions to check attestations
    function hasAttested(uint tokenId, uint8 field) public view _tokenExists(tokenId) returns (bool) {
        require(allowedFields[field], "Invalid field.");
        Identity storage identity = tokenDirectory[tokenId];
        return identity.fieldsAttestedTo.contains(field);
    }

    function hasAttested(uint tokenId, uint8 field, string entry) public view _tokenExists(tokenId) returns (bool) {
        require(allowedFields[field], "Invalid field.");
        Identity storage identity = tokenDirectory[tokenId];
        bytes32 entryLookup = keccak256(abi.encodePacked(entry));
        return identity.fields[field].entriesAttestedTo.contains(entryLookup);
    }

    // functions to read token values
    function getDetails(uint tokenId) public view _tokenExists(tokenId) returns (
        address owner,
        string hydroId,
        uint8[] fieldsAttestedTo,
        address[] resolversFor
    ) {
        Identity storage identity = tokenDirectory[tokenId];
        return (
            identity.owner,
            identity.hydroId,
            identity.fieldsAttestedTo.members,
            identity.resolversFor.members
        );
    }

    function getDetails(uint tokenId, address resolver) public view _tokenExists(tokenId)
        returns (uint withdrawAllowance)
    {
        Identity storage identity = tokenDirectory[tokenId];
        require(identity.resolversFor.contains(resolver));

        return identity.resolvers[resolver].withdrawAllowance;
    }

    function getDetails(uint tokenId, uint8 field) public view _tokenExists(tokenId)
        returns (bytes32[] entriesAttestedTo)
    {
        Identity storage identity = tokenDirectory[tokenId];
        require(identity.fieldsAttestedTo.contains(field));

        return identity.fields[field].entriesAttestedTo.members;
    }

    function getDetails(uint tokenId, uint8 field, string entry) public view
        returns (string entryName, bytes32 saltedHash, uint blockNumber)
    {
        return getDetails(tokenId, field, keccak256(abi.encodePacked(entry)));
    }

    function getDetails(uint tokenId, uint8 field, bytes32 entryLookup) public view _tokenExists(tokenId)
        returns (string entryName, bytes32 saltedHash, uint blockNumber)
    {
        Identity storage identity = tokenDirectory[tokenId];
        require(identity.fieldsAttestedTo.contains(field));
        require(identity.fields[field].entriesAttestedTo.contains(entryLookup));

        return (
            identity.fields[field].entries[entryLookup].entryName,
            identity.fields[field].entries[entryLookup].saltedHash,
            identity.fields[field].entries[entryLookup].blockNumber
        );
    }

    // functions that enable HYDRO functionality
    function receiveApproval(address _sender, uint amount, address _tokenAddress, bytes) public {
        require(msg.sender == _tokenAddress);
        require(_tokenAddress == hydroTokenAddress);
        ERC20 hydro = ERC20(_tokenAddress);
        require(hydro.transferFrom(_sender, address(this), amount));
        deposits[_sender] = deposits[_sender].add(amount);
        emit SnowflakeDeposit(_sender, amount);
    }

    function transferSnowflakeBalance(address to, uint amount) public {
        _transferSnowflakeBalance(msg.sender, to, amount);
    }

    function withdrawSnowflakeBalance(uint amount) public {
        require(amount > 0);
        require(deposits[msg.sender] >= amount, "Your cannot withdraw more than you have deposited.");
        deposits[msg.sender] = deposits[msg.sender].sub(amount);
        ERC20 hydro = ERC20(hydroTokenAddress);
        require(hydro.transfer(msg.sender, amount));
        emit SnowflakeWithdraw(msg.sender, amount);
    }

    // only callable from resolvers with withdraw allowances
    function transferOnBehalfOf(address from, address to, uint amount) public _hasToken(from, true) {
        Identity storage identity = tokenDirectory[ownerToToken[from]];
        require(identity.resolversFor.contains(msg.sender), "This resolver has not been set by the from tokenholder.");
        
        if (identity.resolvers[msg.sender].withdrawAllowance < amount) {
            emit InsufficientAllowance(
                ownerToToken[from], msg.sender, identity.resolvers[msg.sender].withdrawAllowance, amount
            );
            require(false, "Resolver has inadequate allowance.");
        }

        identity.resolvers[msg.sender].withdrawAllowance = identity.resolvers[msg.sender].withdrawAllowance.sub(amount);
        _transferSnowflakeBalance(from, to,  amount);
    }

    function _transferSnowflakeBalance(address from, address to, uint amount) internal {
        require(to != address(this), "This contract cannot hold token balances on its own behalf.");
        require(amount > 0);
        require(deposits[from] >= amount, "Your balance is too low to transfer this amount.");
        deposits[from] = deposits[from].sub(amount);
        deposits[to] = deposits[to].add(amount);
        emit SnowflakeTransfer(from, to, amount);
    }

    // events
    event SnowflakeDeposit(address indexed depositor, uint amount);
    event SnowflakeTransfer(address indexed from, address indexed to, uint amount);
    event SnowflakeWithdraw(address indexed depositor, uint amount);

    event SnowflakeMinted(uint tokenId, address minter);

    event ResolverWhitelisted(address indexed resolver, address sponsor);

    event ResolversAdded(uint indexed tokenId, address[] resolvers, uint[] withdrawAllowances);
    event ResolversAllowanceChanged(uint indexed tokenId, address[] resolvers, uint[] withdrawAllowances);
    event ResolversRemoved(uint indexed tokenId, address[] resolvers);

    event InsufficientAllowance(uint indexed tokenId, address resolver, uint currentAllowance, uint requestedWithdraw);
}