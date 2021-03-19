// SPDX-License-Identifier: MIT



import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import './uniswapv2/libraries/UniswapV2Library.sol';
import "./ZooToken.sol";
import "./ZooRouter.sol";


interface IZooKeeper {
  //Zookeeper is in charge of the zoo
  //It control the speed of ZOO release by rules 
  function requestForZOO(uint256 amount) external returns (uint256);
}


// ZooSwapMining is interesting place where you can get more ZOO as long as you stake
// Have fun reading it. Hopefully it's bug-free. God bless.

contract ZooSwapMining is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of Zos
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accZooPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accZooPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }
    // Info of each pool.
    struct PoolInfo {
        address lpToken; // Address of LP token contract.
        address archorTokenAddr; //the anchor token for swap weight
        uint256 lpTokenTotal;
        uint256 allocPoint; // How many allocation points assigned to this pool. ZOOs to distribute per block.
        uint256 lastRewardBlock; // Last block number that ZOOs distribution occurs.
        uint256 accZooPerShare; // Accumulated ZOOs per share, times 1e12. See below.
    }

    // The ZOO TOKEN!
    ZooToken public zoo;
    //The ZOORouter addr
    address public routerAddr;
    address public factoryAddr;
    // The ZOO Keeper
    IZooKeeper public zookeeper;
    // ZOO tokens created per block.
    uint256 public zooPerBlock;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when ZOO mining starts
    uint256 public startBlock;
    // The block number of half cycle
    uint256 public  blockNumberOfHalfCycle;
    
    //Pos start from 1, pos-1 equals pool index 
    mapping(address => uint256) public tokenPairMapPoolPos;



    event MinedBySwap(address indexed user, uint256 indexed pid, uint256 zooAmount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 lpBurned,uint256 zooAmount);

    modifier onlyRouter() {
        require(msg.sender == routerAddr, "ZooSwapMining: sender isn't the router");
        _;
    }


    constructor(
        ZooToken _zoo,
        IZooKeeper _zookeeper,
        address payable _routerAddr,
        uint256 _zooPerBlock,
        uint256 _startBlock,
        uint256 _blockNumberOfHalfCycle
    ) public {
        zoo = _zoo;
        zookeeper = _zookeeper;
        routerAddr = _routerAddr;
        zooPerBlock = _zooPerBlock;
        startBlock = _startBlock;
        blockNumberOfHalfCycle = _blockNumberOfHalfCycle;

        factoryAddr = ZooRouter(_routerAddr).factory();
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }


    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        address _archorTokenAddr,
        address _anotherTokenAddr,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        address _lpToken = UniswapV2Library.pairFor(factoryAddr, _archorTokenAddr, _anotherTokenAddr);
        uint256 lastRewardBlock =
            block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                archorTokenAddr:_archorTokenAddr,
                lpTokenTotal : 0, 
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accZooPerShare: 0
            })
        );
        tokenPairMapPoolPos[_lpToken] =  poolInfo.length;
    }

    // Update the given pool's ZOO allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        uint256 _halfCycle = blockNumberOfHalfCycle;
        uint256 current ;
        uint256 divider = 1;
        uint256 total = 0;
        for (current = startBlock ; current < _to ; current+=_halfCycle) {
            uint256 nextPos = current+_halfCycle;

            if (nextPos > _from) {
                total += nextPos.sub(_from).div(divider);
            }

            if(nextPos > _to) { //last range
                total += _to.sub(current).div(divider);
            }

            divider = divider.mul(2);
        }
        return total;

    }



    // View function to see pending ZOOs on frontend.
    function pendingZooAll(address _user)
        external
        view
        returns (uint256)
    {
        uint256 total = 0;
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; ++_pid) {
            PoolInfo storage pool = poolInfo[_pid];
            UserInfo storage user = userInfo[_pid][_user];
            uint256 accZooPerShare = pool.accZooPerShare;
            uint256 lpSupply = pool.lpTokenTotal;
            if (block.number > pool.lastRewardBlock && lpSupply != 0) {
                uint256 multiplier =
                    getMultiplier(pool.lastRewardBlock, block.number);
                uint256 zooReward =
                    multiplier.mul(zooPerBlock).mul(pool.allocPoint).div(
                        totalAllocPoint
                    );
                accZooPerShare = accZooPerShare.add(
                    zooReward.mul(1e12).div(lpSupply)
                );
            }
            total += user.amount.mul(accZooPerShare).div(1e12).sub(user.rewardDebt);
        }
        return total;
    }



    // View function to see pending ZOOs on frontend.
    function pendingZoo(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accZooPerShare = pool.accZooPerShare;
        uint256 lpSupply = pool.lpTokenTotal;
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier =
                getMultiplier(pool.lastRewardBlock, block.number);
            uint256 zooReward =
                multiplier.mul(zooPerBlock).mul(pool.allocPoint).div(
                    totalAllocPoint
                );
            accZooPerShare = accZooPerShare.add(
                zooReward.mul(1e12).div(lpSupply)
            );
        }
        return user.amount.mul(accZooPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpTokenTotal;
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 zooReward =
            multiplier.mul(zooPerBlock).mul(pool.allocPoint).div(
                totalAllocPoint
            );

        zooReward = zookeeper.requestForZOO(zooReward);


        pool.accZooPerShare = pool.accZooPerShare.add(
            zooReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    function withdrawAll() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            uint256 liqBalance = userInfo[pid][msg.sender].amount; 
            _withdraw(pid, liqBalance);
        }
    }

    function withdraw(uint256 _pid,uint256 _burned) public {
        _withdraw(_pid, _burned);
    }

    function swap(address account, address input, address output, uint256 inAmount  ,uint256 outAmount) onlyRouter external returns (bool){
        address pair = UniswapV2Library.pairFor(factoryAddr, input, output);
        // no error if pair not set 
        if (tokenPairMapPoolPos[ pair ] == 0 ){
            return true;
        }
        uint256 _pid = tokenPairMapPoolPos[ pair ].sub(1);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][account];
        updatePool(_pid);
        uint256 _amount;
        if( pool.archorTokenAddr == input ){
            _amount = inAmount;
        }else{
            _amount = outAmount;
        }

        pool.lpTokenTotal = pool.lpTokenTotal.add(_amount);
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.rewardDebt.add(_amount.mul(pool.accZooPerShare)).div(1e12);

        emit MinedBySwap(account, _pid, _amount);
        return true;
    }


    // Safe zoo transfer function, just in case if rounding error causes pool to not have enough ZOOs.
    function safeZooTransfer(address _to, uint256 _amount) internal {
        uint256 zooBal = zoo.balanceOf(address(this));
        if (_amount > zooBal) {
            zoo.transfer(_to, zooBal);
        } else {
            zoo.transfer(_to, _amount);
        }
    }

    function _withdraw(uint256 _pid,uint256 _burned) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _burned, "withdraw: not good");

        updatePool(_pid);
        uint256 pending =
            user.amount.mul(pool.accZooPerShare).div(1e12).sub(
                user.rewardDebt
            );
        safeZooTransfer(msg.sender, pending);
        //burn all lp
        pool.lpTokenTotal = pool.lpTokenTotal.sub(_burned);
        user.amount = user.amount.sub(_burned);

        user.rewardDebt = user.amount.mul(pool.accZooPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid,_burned, pending);
    }


}