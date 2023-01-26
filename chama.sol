contract Chama {
    address payable public owner;
    mapping (address => uint) public contributions;
    mapping (address => bool) public participation;
    address[] public members;
    uint public totalFunds;

    constructor() public {
        owner = msg.sender;
        members.push(msg.sender);
    }

    function addMember(address payable _member) public {
        require(msg.sender == owner, "Only the owner can add members.");
        require(_member != address(0), "Invalid address.");
        require(members.length == 0 || members.indexOf(_member) == -1, "Member already exists.");
        members.push(_member);
    }

    function contribute() public payable {
        require(msg.sender != address(0), "Invalid address.");
        require(members.indexOf(msg.sender) != -1, "You are not a member.");
        contributions[msg.sender] += msg.value;
        totalFunds += msg.value;
    }

    function requestFunds(uint _amount) public {
        require(msg.sender != address(0), "Invalid address.");
        require(members.indexOf(msg.sender) != -1, "You are not a member.");
        require(_amount <= contributions[msg.sender], "You cannot request more than your contributions.");
        require(participation[msg.sender], "You must participate in order to request funds.");
        for (uint i = 0; i < members.length; i++) {
            if (members[i] != msg.sender) {
                require(address(this).transfer(_amount), "Transfer failed.");
            }
        }
    }

    function approveRequest(address _member) public {
        require(msg.sender != address(0), "Invalid address.");
        require(members.indexOf(msg.sender) != -1, "You are not a member.");
        require(members.indexOf(_member) != -1, "This member does not exist.");
        participation[_member] = true;
    }

    function distributeFunds() public {
        require(msg.sender == owner, "Only the owner can distribute funds.");
        for (uint i = 0; i < members.length; i++) {
            uint share = contributions[members[i]] / members.length;
            require(address(members[i]).transfer(share), "Transfer failed.");
        }
    }
}