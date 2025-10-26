// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
  SimpleBetting
  - 每注固定金額 (betAmount)
  - 扣 5% 手續費 (feePercent)
  - 參賽者需在 kycVerified 白名單 (owner 手動加入)
  - Owner 可開始新一輪 (startRound)，玩家下注 (placeBet)
  - Owner 呼叫 drawWinner 選出中獎者（示範用 block.prevrandao）
  - 可暫停 / 恢復合約
  - 重入防護，事件紀錄
*/

contract SimpleBetting {
    address public owner;
    bool public paused;

    uint256 public betAmount;         // 單注金額 (wei)
    uint256 public feePercent;        // 手續費百分比
    uint256 public currentRound;      // 當前輪數
    uint256 public maxBetsPerAddress; // 每位玩家每輪最大下注次數
    uint256 public maxPlayersPerRound;// 每輪最多玩家數

    mapping(uint256 => address[]) public roundPlayers;
    mapping(uint256 => mapping(address => uint256)) public roundBetCount;
    mapping(address => uint256) public pendingWithdrawals;
    uint256 public collectedFees;

    mapping(address => bool) public kycVerified;

    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // 事件
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event PauseChanged(bool isPaused);
    event BetPlaced(uint256 indexed round, address indexed player, uint256 amount);
    event RoundStarted(uint256 indexed round);
    event WinnerDrawn(uint256 indexed round, address indexed winner, uint256 prize);
    event Withdrawal(address indexed who, uint256 amount);
    event KycUpdated(address indexed user, bool verified);
    event BetAmountChanged(uint256 oldAmount, uint256 newAmount);
    event FeePercentChanged(uint256 oldFee, uint256 newFee);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier notPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "Reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor(uint256 _betAmount, uint256 _feePercent) {
        owner = msg.sender;
        betAmount = _betAmount;
        feePercent = _feePercent;
        currentRound = 1;
        maxBetsPerAddress = 5;
        maxPlayersPerRound = 100;
        _status = _NOT_ENTERED;
    }

    // === 管理功能 ===
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function setPause(bool _p) external onlyOwner {
        paused = _p;
        emit PauseChanged(_p);
    }

    function setBetAmount(uint256 _amount) external onlyOwner {
        emit BetAmountChanged(betAmount, _amount);
        betAmount = _amount;
    }

    function setFeePercent(uint256 _feePercent) external onlyOwner {
        require(_feePercent <= 100, "fee <= 100");
        emit FeePercentChanged(feePercent, _feePercent);
        feePercent = _feePercent;
    }

    function setMaxBetsPerAddress(uint256 _max) external onlyOwner {
        maxBetsPerAddress = _max;
    }

    function setMaxPlayersPerRound(uint256 _max) external onlyOwner {
        maxPlayersPerRound = _max;
    }

    // === KYC 管理 ===
    function setKycVerified(address user, bool verified) external onlyOwner {
        kycVerified[user] = verified;
        emit KycUpdated(user, verified);
    }

    // === 遊戲邏輯 ===
    function startRound() external onlyOwner {
        currentRound += 1;
        emit RoundStarted(currentRound);
    }

    function placeBet() external payable notPaused nonReentrant {
        require(kycVerified[msg.sender], "Not KYC verified");
        require(msg.value == betAmount, "Send exact betAmount");
        require(roundPlayers[currentRound].length < maxPlayersPerRound, "Round full");
        require(roundBetCount[currentRound][msg.sender] < maxBetsPerAddress, "Too many bets");

        roundPlayers[currentRound].push(msg.sender);
        roundBetCount[currentRound][msg.sender] += 1;

        emit BetPlaced(currentRound, msg.sender, msg.value);
    }

    function drawWinner() external onlyOwner notPaused nonReentrant {
        address[] storage players = roundPlayers[currentRound];
        require(players.length > 0, "No players this round");

        uint256 totalPool = betAmount * players.length;
        uint256 fee = (totalPool * feePercent) / 100;
        uint256 prize = totalPool - fee;
        collectedFees += fee;

        // ✅ 使用 prevrandao（取代 difficulty）
        uint256 rand = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, players.length)));
        uint256 winnerIndex = rand % players.length;
        address winner = players[winnerIndex];

        pendingWithdrawals[winner] += prize;

        emit WinnerDrawn(currentRound, winner, prize);

        delete roundPlayers[currentRound];
    }

    function withdrawPrize() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "No funds");
        pendingWithdrawals[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");

        emit Withdrawal(msg.sender, amount);
    }

    function ownerWithdrawFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "zero address");
        uint256 amount = collectedFees;
        require(amount > 0, "No fees");
        collectedFees = 0;

        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");

        emit Withdrawal(to, amount);
    }

    function refundCurrentRound() external onlyOwner nonReentrant {
        address[] storage players = roundPlayers[currentRound];
        require(players.length > 0, "No players");

        for (uint256 i = 0; i < players.length; i++) {
            address player = players[i];
            (bool success, ) = payable(player).call{value: betAmount}("");
            if (!success) {
                pendingWithdrawals[player] += betAmount;
            }
        }

        delete roundPlayers[currentRound];
    }

    receive() external payable {
        revert("Use placeBet()");
    }

    fallback() external payable {
        revert("Use placeBet()");
    }

    function getPlayersCount(uint256 round) external view returns (uint256) {
        return roundPlayers[round].length;
    }

    function fundContract() external payable onlyOwner {}
}
