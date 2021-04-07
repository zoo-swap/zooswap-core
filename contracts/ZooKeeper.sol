// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ZooToken.sol";


contract ZooKeeper is Ownable {
    using SafeMath for uint256;

    struct ZooApplicatioin {
        address zooMember; // Address of member
        uint256 totalValue; // Total zoo can be request
        uint256 transferedValue; //Total transferd zoo 
        uint256 perBlockLimit; //  
        uint256 startBlock; // 
    } 


    // The ZOO TOKEN!
    ZooToken public zoo;
    mapping(address => ZooApplicatioin) public applications;
    bool public appPublished ; //when published ,applications can not be modified
    address public immutable devAddr; //1/4 extra
    address public immutable investorAddr; // 1/8 extra
    address public immutable foundationAddr;// 1/8 extra


    event ApplicationAdded(address indexed zooMember, uint256 totalValue,uint256 perBlockLimit, uint256 startBlock );
    event ApplicationPublished(address publisher);

    event ZOOForRequestor(address indexed to ,uint256 amount);

    
    modifier appNotPublished() {
        require(!appPublished, "ZooSwapMining: app published");
        _;
    }


    constructor(
        ZooToken _zoo,
        address _devAddr,
        address _investorAddr,
        address _foundationAddr
    ) public {
        require(_devAddr != address(0));
        require(_investorAddr != address(0));
        require(_foundationAddr != address(0)); 
        require(address(_zoo) !=  address(0));

        zoo = _zoo;
        appPublished = false;
        devAddr = _devAddr;
        investorAddr = _investorAddr;
        foundationAddr = _foundationAddr;
    }


    function addApplication(address _zooMember , uint256 _totalValue, uint256 _perBlockLimit,uint256 _startBlock ) public onlyOwner appNotPublished {
        ZooApplicatioin storage app = applications[_zooMember];
        app.zooMember = _zooMember;
        app.totalValue = _totalValue;
        app.transferedValue = 0;
        app.perBlockLimit = _perBlockLimit;
        app.startBlock = _startBlock;
        emit ApplicationAdded(_zooMember,_totalValue,_perBlockLimit,_startBlock);
    
    }

    function publishApplication() public onlyOwner appNotPublished {
        appPublished = true;
        emit ApplicationPublished(msg.sender);
    }
 

    function requestForZOO(uint256 _amount) public  returns (uint256) {
        // when reward is zero,this should not revert because the swap methods still depend on this
        if(_amount == 0){
            return 0;
        }
        ZooApplicatioin storage app = applications[msg.sender];
        require( app.zooMember == msg.sender  , "not zoo member"  );
        require(block.number >app.startBlock,"not start");
        uint256 unlocked = block.number.sub(app.startBlock).mul(app.perBlockLimit);
        uint256 newTransferd = app.transferedValue.add(_amount);
        require(newTransferd <=  unlocked, "transferd is over unlocked "); 
        require(newTransferd <= app.totalValue,"transferd is over total ");

        // when 1 zoo is mint, extra 0.5 should be mint too (0.125 for inverstor,0.125 for foundtaion ,0.25 for dev) 
        //mint to dev,investor,foundation
        zoo.mint(devAddr,_amount.div(4));
        zoo.mint(investorAddr,_amount.div(8));
        zoo.mint(foundationAddr,_amount.div(8));

        if(!zoo.mint(msg.sender,_amount)){
            //zoo not enough
            _amount = 0;
        }else{ 
            //mint ok
            app.transferedValue = newTransferd;
        }

        emit ZOOForRequestor(msg.sender, _amount);
        return _amount;
    }

}
