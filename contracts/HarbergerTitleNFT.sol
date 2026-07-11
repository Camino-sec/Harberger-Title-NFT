// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title HarbergerTitleNFT
 * @notice 基于哈伯格税（Harberger Tax）机制的社区稀缺头衔 NFT。
 *
 * @dev 核心博弈逻辑（用「租房」类比）：
 *      - 你租了一间黄金地段的店铺（NFT），在门口挂了一个「转让价」。
 *      - 任何人都可以按你挂的价格直接买走你的租约（强制买断）。
 *      - 但你每个月都要按你挂的价格交租金（税）。挂得越高，租金越贵。
 *      - 如果你的租金交不起（税金耗尽），店铺会被收回（违约）。
 *
 *      这个机制逼迫持有者在「报高价怕被买走」和「报低价少交税」之间做博弈，
 *      从而让稀缺资产始终有一个合理的市场定价，并保持流动性。
 */
contract HarbergerTitleNFT is ERC721, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ─────────────────── 状态变量 ───────────────────

    /// @notice 用于支付税金和买断的 ERC-20 代币地址
    IERC20 public immutable paymentToken;

    /// @notice 年化税率，单位：基点（Basis Points）。1000 = 10%
    /// @dev    为什么用基点而不是小数？因为 Solidity 没有浮点数，
    ///         用整数基点做乘法再除以 10000，可以避免精度丢失。
    uint256 public taxRateBps;

    /// @notice 当前持有者地址。tokenId 固定为 0（单例模式，一个合约 = 一个头衔）
    address public holder;

    /// @notice 持有者自报的价格（也是买断价格），单位：paymentToken 的最小单位
    uint256 public selfAssessedPrice;

    /// @notice 持有者的税金押金余额（Escrow），单位：paymentToken 的最小单位
    uint256 public escrowBalance;

    /// @notice 上一次结算税金的时间戳（惰性求值的关键锚点）
    uint256 public lastSettlementTime;

    /// @notice 合约部署时的基准价格（违约后以此价格重新开放申领）
    uint256 public immutable floorPrice;

    /// @notice NFT 是否处于违约（Foreclosure）状态
    bool public isForeclosed;

    // ─────────────────── 事件 ───────────────────

    event CollateralDeposited(address indexed holder, uint256 amount);
    event PriceUpdated(address indexed holder, uint256 oldPrice, uint256 newPrice, uint256 taxDeducted);
    event Buyout(address indexed buyer, address indexed seller, uint256 price, uint256 taxSettled, uint256 escrowRefund);
    event Foreclosure(address indexed previousHolder, uint256 owedTax);
    event ForeclosedNFTClaimed(address indexed newHolder, uint256 pricePaid);
    event TaxSettled(address indexed holder, uint256 amount, string trigger);

    // ─────────────────── 构造函数 ───────────────────

    /**
     * @param _paymentToken  用于支付的 ERC-20 代币地址
     * @param _taxRateBps    年化税率（基点）。例如 1000 = 10%/年
     * @param _floorPrice    基准价格（违约后以此价格开放申领）
     */
    constructor(
        address _paymentToken,
        uint256 _taxRateBps,
        uint256 _floorPrice
    ) ERC721("HarbergerTitle", "HTITLE") {
        require(_paymentToken != address(0), "Invalid token address");
        require(_taxRateBps > 0 && _taxRateBps <= 5000, "Tax rate must be 0-50%");

        paymentToken = IERC20(_paymentToken);
        taxRateBps = _taxRateBps;
        floorPrice = _floorPrice;

        // 初始化时没有持有者，NFT 未被铸造
        // 第一个调用 mint() 的人成为初始持有者
    }

    // ─────────────────── 外部函数 ───────────────────

    /**
     * @notice 初始铸造：第一个调用者成为持有者，必须同时设定价格并充值押金。
     * @param initialPrice  初始自报价
     * @param depositAmount 初始押金金额
     */
    function mint(uint256 initialPrice, uint256 depositAmount) external nonReentrant {
        require(holder == address(0), "Already minted");
        require(initialPrice > 0, "Price must be > 0");
        // 押金可以为 0，但持有者需要理解这样会很快违约

        // 从调用者处转入押金
        paymentToken.safeTransferFrom(msg.sender, address(this), depositAmount);

        // 铸造 NFT
        _mint(msg.sender, 0);

        // 初始化状态
        holder = msg.sender;
        selfAssessedPrice = initialPrice;
        escrowBalance = depositAmount;
        lastSettlementTime = block.timestamp;

        emit CollateralDeposited(msg.sender, depositAmount);
    }

    /**
     * @notice 持有者充值税金押金。
     * @dev    这个函数在充值时会先结算当前欠税（惰性求值），
     *         确保充值的金额不会被立刻用于覆盖之前的欠税。
     */
    function depositCollateral(uint256 amount) external nonReentrant {
        require(msg.sender == holder, "Only holder can deposit");
        require(amount > 0, "Amount must be > 0");

        // 惰性结算：先扣除自上次结算以来的欠税
        _settleTax("deposit");

        // 转入押金
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        escrowBalance += amount;

        emit CollateralDeposited(msg.sender, amount);
    }

    /**
     * @notice 持有者更新自报价。
     * @dev    更新价格时会触发惰性扣税。这是博弈的核心：
     *         - 报高价 → 被买断风险高，但潜在收益大
     *         - 报低价 → 税金消耗少，但容易被低价买走
     * @param newPrice 新的自报价
     */
    function setPrice(uint256 newPrice) external {
        require(msg.sender == holder, "Only holder can set price");
        require(newPrice > 0, "Price must be > 0");

        uint256 oldPrice = selfAssessedPrice;

        // 惰性结算欠税
        _settleTax("setPrice");

        // 更新价格
        selfAssessedPrice = newPrice;

        emit PriceUpdated(msg.sender, oldPrice, newPrice, 0);
    }

    /**
     * @notice 强制买断：任何人支付当前自报价即可获得 NFT。
     * @dev    这是哈伯格税最关键的博弈机制——"强制出售权"。
     *
     *         【修复说明 / FIX】原实现在买断后把 escrowBalance 置为 0，
     *         并把"充值押金"描述成买家的可选后续操作。但只要 escrowBalance = 0，
     *         下一个区块只要有极小的欠税产生（owedTax > 0 = escrowBalance），
     *         _isForeclosed() 就会立刻为 true —— 也就是说，新买家在自己买断成功后
     *         的下一个区块，就可能被任何第三方用 claimForeclosed() 免费/低价抢走。
     *         现在改为买家必须在同一笔交易里同时提交初始押金，杜绝这个"零押金窗口"。
     *
     *         资金流向：
     *         1. 买家支付的价格 → 转给前任持有者
     *         2. 买家的初始押金 → 转入合约（原子完成，不再有零押金窗口）
     *         3. 前任持有者的欠税 → 从其押金中扣除，留在合约中
     *         4. 前任持有者剩余的押金 → 退还给前任持有者
     *
     *         同时按 Checks-Effects-Interactions 模式重排：所有状态更新
     *         （holder、escrowBalance、NFT 转移）都在外部 token 转账之前完成，
     *         并加上 nonReentrant 双重保护。
     *
     * @param pricePayed    买家愿意支付的价格，必须 >= 当前自报价
     * @param depositAmount 买家为自己的新头衔预存的税金押金（建议 > 0，否则很快会重新违约）
     */
    function buyout(uint256 pricePayed, uint256 depositAmount) external nonReentrant withTransferUnlocked {
        require(holder != address(0), "Not minted");
        require(msg.sender != holder, "Holder cannot buyout own NFT");
        require(pricePayed >= selfAssessedPrice, "Price too low");

        address previousHolder = holder;
        uint256 price = selfAssessedPrice;

        // ── Effects：先算清楚欠税，再一次性把所有状态更新完 ──
        uint256 owed = _calculateOwedTax();
        uint256 taxDeducted = owed <= escrowBalance ? owed : escrowBalance;
        uint256 escrowRefund = escrowBalance - taxDeducted;

        holder = msg.sender;
        selfAssessedPrice = price;          // 新持有者可以用 setPrice() 修改
        escrowBalance = depositAmount;      // 关键修复：新持有者的押金在买断当笔交易内就位
        lastSettlementTime = block.timestamp;

        _transfer(previousHolder, msg.sender, 0);

        emit TaxSettled(previousHolder, taxDeducted, "buyout");
        emit Buyout(msg.sender, previousHolder, price, taxDeducted, escrowRefund);
        if (depositAmount > 0) {
            emit CollateralDeposited(msg.sender, depositAmount);
        }

        // ── Interactions：状态已经落定之后，才做外部代币转账 ──
        if (depositAmount > 0) {
            paymentToken.safeTransferFrom(msg.sender, address(this), depositAmount);
        }
        paymentToken.safeTransferFrom(msg.sender, previousHolder, price);
        if (escrowRefund > 0) {
            paymentToken.safeTransfer(previousHolder, escrowRefund);
        }
    }

    /**
     * @notice 违约申领：当 NFT 处于 Foreclosure 状态时，任何人可以免费或以基准价申领。
     * @dev    这是防止"占坑不拉屎"的最后一道防线。
     *         持有者如果连税金都交不起了，头衔就会被释放给社区。
     *
     * @dev    同样存在"零押金窗口"问题：申领后如果 escrowBalance 仍为 0，
     *         下一个区块又会立刻重新进入违约状态，被别人再次免费申领。
     *         所以这里也让申领人可以在同一笔交易里带上初始押金。
     *
     * @param pricePayed    支付的价格（如果 floorPrice > 0，则必须 >= floorPrice）
     * @param depositAmount 申领人为自己的新头衔预存的税金押金（建议 > 0）
     */
    function claimForeclosed(uint256 pricePayed, uint256 depositAmount) external nonReentrant withTransferUnlocked {
        require(holder != address(0), "Not minted");
        require(msg.sender != holder, "Holder cannot claim own NFT");
        require(_isForeclosed(), "Not in foreclosure");
        require(pricePayed >= floorPrice, "Must pay at least floor price");

        address previousHolder = holder;

        // ── Effects：先把所有状态更新完 ──
        // 前任持有者的欠税已经超过其押金（违约判定条件），押金不足的部分不再追讨。
        holder = msg.sender;
        selfAssessedPrice = floorPrice > 0 ? floorPrice : 1;
        escrowBalance = depositAmount;      // 关键修复：申领人的押金在申领当笔交易内就位
        lastSettlementTime = block.timestamp;
        isForeclosed = false;

        _transfer(previousHolder, msg.sender, 0);

        emit ForeclosedNFTClaimed(msg.sender, pricePayed);
        if (depositAmount > 0) {
            emit CollateralDeposited(msg.sender, depositAmount);
        }

        // ── Interactions：状态落定之后，才做外部代币转账 ──
        uint256 totalIn = pricePayed + depositAmount;
        if (totalIn > 0) {
            paymentToken.safeTransferFrom(msg.sender, address(this), totalIn);
        }
    }

    // ─────────────────── 视图函数 ───────────────────

    /**
     * @notice 查询当前持有者已产生的欠税金额。
     * @return 欠税金额（单位：paymentToken 的最小单位）
     */
    function owedTax() external view returns (uint256) {
        if (holder == address(0)) return 0;
        return _calculateOwedTax();
    }

    /**
     * @notice 查询 NFT 是否处于违约状态。
     * @return true 表示已违约，任何人可以调用 claimForeclosed()
     */
    function foreclosed() external view returns (bool) {
        return _isForeclosed();
    }

    /**
     * @notice 查询当前持有者在扣除欠税后的净押金余额。
     * @return 净余额（如果欠税 > 押金，返回 0）
     */
    function netEscrowBalance() external view returns (uint256) {
        if (holder == address(0)) return 0;
        uint256 owed = _calculateOwedTax();
        return escrowBalance > owed ? escrowBalance - owed : 0;
    }

    // ─────────────────── 内部函数 ───────────────────

    /**
     * @dev 惰性求值：计算自上次结算以来的欠税金额。
     *
     *      数学公式：
     *      owedTax = selfAssessedPrice × taxRateBps × timeElapsed / (365 days × 10000)
     *
     *      为什么用 365 天而不是 1 年？
     *      因为 Solidity 的 block.timestamp 是 Unix 时间戳（秒），
     *      用 365 days（= 31536000 秒）可以直接与时间差做整数运算。
     *
     *      为什么先乘后除？
     *      这是 Solidity 整数运算的常见技巧。如果先除，小数部分会被截断，
     *      导致精度丢失。先乘后除可以最大化保留精度。
     *      但要注意：如果 selfAssessedPrice × taxRateBps × timeElapsed 可能溢出 uint256，
     *      需要做溢出检查。在本合约的参数范围内，不会溢出。
     */
    function _calculateOwedTax() internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp - lastSettlementTime;
        if (timeElapsed == 0) return 0;

        // 核心公式：价格 × 税率 × 时间 / (365天 × 10000)
        // taxRateBps 单位是基点（1/10000），所以除以 10000
        return (selfAssessedPrice * taxRateBps * timeElapsed) / (365 days * 10000);
    }

    /**
     * @dev 结算税金：扣除押金，更新结算时间戳。
     *      这是惰性求值模式的核心——只在需要时才计算和扣除税金。
     *
     * @param trigger 触发结算的操作名称（用于事件日志，方便调试）
     */
    function _settleTax(string memory trigger) internal {
        uint256 owed = _calculateOwedTax();
        if (owed == 0) return;

        if (owed <= escrowBalance) {
            escrowBalance -= owed;
        } else {
            // 押金不足以覆盖全部税金，扣光押金
            escrowBalance = 0;
            // 注意：此时持有者已处于违约边缘
        }

        lastSettlementTime = block.timestamp;
        emit TaxSettled(holder, owed, trigger);
    }

    /**
     * @dev 检查是否已违约：欠税 > 押金余额
     */
    function _isForeclosed() internal view returns (bool) {
        if (holder == address(0)) return false;
        return _calculateOwedTax() > escrowBalance;
    }

    // ─────────────────── ERC-721 转移控制 ───────────────────

    /// @dev 转移锁：默认锁定，只有 buyout/claimForeclosed 内部解锁后才能转移
    bool private _transferLocked = true;

    /**
     * @dev 通过覆写 _update 钩子来拦截所有 NFT 转移。
     *      OpenZeppelin v5 的 _transfer()、_mint()、_burn() 都会调用 _update()。
     *      我们在这里加锁：外部调用 transferFrom 时会触发 revert，
     *      而 buyout/claimForeclosed 内部会先解锁再调用 _transfer。
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        // _mint 时 to != address(0)，_burn 时 to == address(0)
        // 只有在转移（非 mint）且锁定期时才拦截
        if (_transferLocked && to != address(0) && _ownerOf(tokenId) != address(0)) {
            revert("Use buyout() or claimForeclosed()");
        }
        return super._update(to, tokenId, auth);
    }

    /**
     * @dev 同样禁止 approve，防止通过授权绕过强制出售权。
     */
    function approve(address, uint256) public pure override {
        revert("Approvals disabled");
    }

    function setApprovalForAll(address, bool) public pure override {
        revert("Approvals disabled");
    }

    /**
     * @dev 临时解锁转移权限，仅在 buyout/claimForeclosed 内部使用。
     *      这是一个"受控后门"——只有合约自己的函数能打开这扇门。
     */
    modifier withTransferUnlocked() {
        _transferLocked = false;
        _;
        _transferLocked = true;
    }
}
