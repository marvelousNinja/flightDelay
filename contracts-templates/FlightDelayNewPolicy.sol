/**
 * FlightDelay with Oraclized Underwriting and Payout
 *
 * @description NewPolicy contract.
 * @copyright (c) 2017 etherisc GmbH
 * @author Christoph Mussenbrock
 *
 */

@@include('./templatewarning.txt')

pragma solidity @@include('./solidity_version_string.txt');

import "./FlightDelayControlledContract.sol";
import "./FlightDelayConstants.sol";
import "./FlightDelayDatabaseInterface.sol";
import "./FlightDelayAccessControllerInterface.sol";
import "./FlightDelayLedgerInterface.sol";
import "./FlightDelayUnderwriteInterface.sol";
import "./convertLib.sol";

contract FlightDelayNewPolicy is 

	FlightDelayControlledContract,
	FlightDelayConstants,
	convertLib

{

	FlightDelayAccessControllerInterface FD_AC;
	FlightDelayDatabaseInterface FD_DB;
	FlightDelayLedgerInterface FD_LG;
	FlightDelayUnderwriteInterface FD_UW;

	function FlightDelayNewPolicy(address _controller) {

		setController(_controller, 'FD.NewPolicy');

	}

	function setContracts() onlyController {

		FD_AC = FlightDelayAccessControllerInterface(getContract('FD.AccessController'));
		FD_DB = FlightDelayDatabaseInterface(getContract('FD.Database'));
		FD_LG = FlightDelayLedgerInterface(getContract('FD.Ledger'));
		FD_UW = FlightDelayUnderwriteInterface(getContract('FD.Underwrite'));

		FD_AC.setPermissionByAddress(101, 0x1);
		FD_AC.setPermissionById(102, 'FD.Owner');
	}

	function bookAndCalcRemainingPremium() internal returns (uint) {

		uint v = msg.value;
		uint reserve = v * reservePercent / 100;
		uint remain = v - reserve;
		uint reward = remain * rewardPercent / 100;

		FD_LG.bookkeeping(Acc.Balance, Acc.Premium, v);
		FD_LG.bookkeeping(Acc.Premium, Acc.RiskFund, reserve);
		FD_LG.bookkeeping(Acc.Premium, Acc.Reward, reward);

		return (uint(remain - reward));

	}

	function maintenanceMode(bool _on) {
		if (FD_AC.checkPermission(102, msg.sender)) {
			FD_AC.setPermissionByAddress(101, 0x0, _on);
		}
	}

	// create new policy
	function newPolicy(
		bytes32 _carrierFlightNumber, 
		bytes32 _departureYearMonthDay, 
		uint _departureTime, 
		uint _arrivalTime
		) payable {

		// here we can switch it off.
		FD_AC.checkPermission(101, 0x1);

		// forward premium
		FD_LG.receiveFunds.value(msg.value)(Acc.Premium);

		// sanity checks:
		// don't Accept too low or too high policies

		if (msg.value < minPremium || msg.value > maxPremium) {

			LOG_PolicyDeclined(0, 'Invalid premium value');
			FD_LG.sendFunds(msg.sender, Acc.Premium, msg.value);
			return;

		}

        // don't Accept flights with departure time earlier than in 24 hours, 
		// or arrivalTime before departureTime, 
		// or departureTime after Mon, 26 Sep 2016 12:00:00 GMT
		uint dmy = to_Unixtime(_departureYearMonthDay);
		
// #ifdef debug
		LOG_uint_time('NewPolicy: dmy: ', dmy);
		LOG_uint_time('NewPolicy: _departureTime: ', _departureTime);
// #endif

        if (
			_arrivalTime < _departureTime ||
			_arrivalTime > _departureTime + maxFlightDuration ||
			_departureTime < now + minTimeBeforeDeparture ||
			_departureTime > contractDeadline ||
			_departureTime < dmy ||
			_departureTime > dmy + 24 hours
			) {

			LOG_PolicyDeclined(0, 'Invalid arrival/departure time');
			FD_LG.sendFunds(msg.sender, Acc.Premium, msg.value);
			return;

        }
				
		bytes32 riskId = FD_DB.createUpdateRisk(
			_carrierFlightNumber, 
			_departureYearMonthDay, 
			_arrivalTime
			);
		
		uint cumulatedWeightedPremium;
		uint premiumMultiplier;
		(cumulatedWeightedPremium, premiumMultiplier) = FD_DB.getPremiumFactors(riskId);

		// roughly check, whether maxCumulatedWeightedPremium will be exceeded
		// (we Accept the inAccuracy that the real remaining premium is 3% lower), 
		// but we are conservative;
		// if this is the first policy, the left side will be 0
		if (msg.value * premiumMultiplier + cumulatedWeightedPremium >= 
			maxCumulatedWeightedPremium) {

			LOG_PolicyDeclined(0, 'Cluster risk');
			FD_LG.sendFunds(msg.sender, Acc.Premium, msg.value);
			return;

		} else if (cumulatedWeightedPremium == 0) {
			// at the first police, we set r.cumulatedWeightedPremium to the max.
			// this prevents further polices to be Accepted, until the correct
			// value is calculated after the first callback from the oracle.
			FD_DB.setPremiumFactors(riskId, maxCumulatedWeightedPremium, premiumMultiplier);
		}

		uint premium = bookAndCalcRemainingPremium();
		uint policyId = FD_DB.createPolicy(msg.sender, premium, riskId);

		if (premiumMultiplier > 0) {
			FD_DB.setPremiumFactors(
				riskId, 
				cumulatedWeightedPremium + premium * premiumMultiplier,
				premiumMultiplier);
		}

		// now we have successfully applied
		FD_DB.setState(policyId, policyState.Applied, now, 'Policy applied by customer');
		LOG_PolicyApplied(policyId, msg.sender, _carrierFlightNumber, premium);

		FD_UW.scheduleUnderwriteOraclizeCall(policyId, _carrierFlightNumber);

	}

}
