// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import "./Set.sol";
import "./TransientStorage.sol";
import "./interfaces/ICreditVaultProtocol.sol";
import "./interfaces/ICreditVault.sol";

contract CreditVaultProtocol is ICVP, TransientStorage {
    using Set for SetStorage;

    // Constants

    string public constant name = "Credit Vault Protocol - CVP";

    address internal constant ERC1820_REGISTRY =
        0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;

    uint8 internal constant BATCH_DEPTH__INIT = 0;
    uint8 internal constant BATCH_DEPTH__MAX = 9;

    // Storage
    mapping(address account => mapping(address operator => bool isOperator))
        public accountOperators;

    mapping(address account => SetStorage) internal accountCollaterals;
    mapping(address account => SetStorage) internal accountControllers;

    // Every Ethereum address has 256 accounts in the CVP (including the primary account - called the owner).
    // Each account has an account ID from 0-255, where 0 is the owner account's ID. In order to compute the account
    // addresses, the account ID is treated as a uint and XORed (exclusive ORed) with the Ethereum address.
    // In order to record the owner of a group of 256 accounts, the CVP uses a definition of a prefix. A prefix is a part
    // of an address having the first 19 bytes common with any of the 256 account addresses belonging to the same group.
    // account/152 -> prefix/152
    // To get prefix for the account, it's enough to take the account address and right shift it by 8 bits.
    mapping(uint152 prefix => address owner) internal ownerLookup;

    // Events, Errors

    event AccountOperatorEnabled(
        address indexed account,
        address indexed operator
    );
    event AccountOperatorDisabled(
        address indexed account,
        address indexed operator
    );
    event AccountsOwnerRegistered(
        uint152 indexed prefix,
        address indexed owner
    );
    event ControllerEnabled(
        address indexed account,
        address indexed controller
    );
    event ControllerDisabled(
        address indexed account,
        address indexed controller
    );

    error CVP_NotAuthorized();
    error CVP_AccountOwnerNotRegistered();
    error CVP_InvalidAddress();
    error CVP_ChecksReentrancy();
    error CVP_ImpersonateReentancy();
    error CVP_BatchDepthViolation();
    error CVP_ControllerViolation();
    error CVP_AccountStatusViolation(address account, bytes data);
    error CVP_VaultStatusViolation(address vault, bytes data);
    error CVP_RevertedBatchResult(
        BatchResult[] batchItemsResult,
        BatchResult[] accountsStatusResult,
        BatchResult[] vaultsStatusResult
    );
    error CVP_BatchPanic();

    // Modifiers

    /// @notice A modifier that allows only the owner or an operator of the account to call the function.
    /// @dev The owner of an account is an address that matches first 19 bytes of the account address. An operator of an account is an address that has been authorized by the owner of an account to perform operations on behalf of the owner.
    /// @param account The address of the account for which it is checked whether msg.sender is the owner or an operator.
    modifier ownerOrOperator(address account) {
        if (
            !haveCommonOwner(msg.sender, account) &&
            !accountOperators[account][msg.sender]
        ) revert CVP_NotAuthorized();
        {
            // if it's an operator calling and we get up to this point
            // (thanks to accountOperators[account][msg.sender] == true), it means that the function setAccountOperator()
            // must have been called previously and the ownerLookup is already set.
            // if it's not an operator calling, it means that owner is msg.sender and the ownerLookup will be set if needed.
            // ownerLookup is set only once on the initial interaction of the account with the CVP.
            uint152 prefix = uint152(uint160(account) >> 8);
            if (ownerLookup[prefix] == address(0)) {
                ownerLookup[prefix] = msg.sender;
                emit AccountsOwnerRegistered(prefix, msg.sender);
            }
        }

        _;
    }

    /// @notice A modifier that checks for checks in progress and impersonate reentrancy.
    modifier nonReentrant() {
        {
            bool checksLock = executionContext.checksLock;
            bool impersonateLock = executionContext.impersonateLock;

            if (checksLock) revert CVP_ChecksReentrancy();
            else if (impersonateLock) revert CVP_ImpersonateReentancy();
        }
        _;
    }

    /// @notice A modifier that sets onBehalfOfAccount in the execution context to the specified account.
    /// @dev Should be used as the last modifier in the function so that context is limited only to the function body.
    modifier onBehalfOfAccountContext(address account) {
        // must be cached in case of CVP reentrancy
        address onBehalfOfAccountCache = executionContext.onBehalfOfAccount;

        executionContext.onBehalfOfAccount = account;
        _;
        executionContext.onBehalfOfAccount = onBehalfOfAccountCache;
    }

    /// @notice A modifier checks whether msg.sender is the only controller for the account.
    modifier authenticateController(address account) {
        {
            uint numOfControllers = accountControllers[account].numElements;
            address controller = accountControllers[account].firstElement;

            if (numOfControllers != 1) revert CVP_ControllerViolation();
            else if (controller != msg.sender) revert CVP_NotAuthorized();
        }
        _;
    }

    // Account owner and operators

    /// @notice Checks whether the specified account and the other account have the same owner.
    /// @dev The function is used to check whether one account is authorized to perform operations on behalf of the other.
    /// @param account The address of the account that is being checked.
    /// @param otherAccount The address of the other account that is being checked.
    /// @return A boolean flag that indicates whether the accounts have the same owner.
    function haveCommonOwner(
        address account,
        address otherAccount
    ) public pure returns (bool) {
        return (uint160(account) | 0xFF) == (uint160(otherAccount) | 0xFF);
    }

    /// @notice Returns the owner for the specified account.
    /// @dev The function will revert if the owner is not registered. Registration of the owner happens on the initial interaction that requires authentication of any of the 256 accounts that belong to the owner.
    /// @param account The address of the account whose owner is being retrieved.
    /// @return owner The address of the account owner. An account owner is an EOA/smart contract which address matches the first 19 bytes of the account address.
    function getAccountOwner(
        address account
    ) external view returns (address owner) {
        owner = ownerLookup[uint152(uint160(account) >> 8)];

        if (owner == address(0)) revert CVP_AccountOwnerNotRegistered();
    }

    /// @notice Sets or unsets an operator for an account.
    /// @dev Only the owner of the account can call this function. An operator is an address that can perform actions for an account on behalf of the owner.
    /// @param account The address of the account whose operator is being set or unset.
    /// @param operator The address of the operator that is being authorized or deauthorized.
    /// @param isAuthorized A boolean flag that indicates whether the operator is authorized or not.
    function setAccountOperator(
        address account,
        address operator,
        bool isAuthorized
    ) public payable virtual {
        // only the account owner can call this function for any of its 256 accounts.
        // the operator cannot be one of the 256 accounts that belong to the owner
        if (!haveCommonOwner(msg.sender, account)) {
            revert CVP_NotAuthorized();
        } else if (haveCommonOwner(msg.sender, operator)) {
            revert CVP_InvalidAddress();
        }

        uint152 prefix = uint152(uint160(account) >> 8);
        if (ownerLookup[prefix] == address(0)) {
            ownerLookup[prefix] = msg.sender;
            emit AccountsOwnerRegistered(prefix, msg.sender);
        }

        if (accountOperators[account][operator] == isAuthorized) return;

        accountOperators[account][operator] = isAuthorized;

        if (isAuthorized) emit AccountOperatorEnabled(account, operator);
        else emit AccountOperatorDisabled(account, operator);
    }

    // Execution internals

    /// @notice Returns current execution context and whether the controllerToCheck is an enabled controller for the account on behalf of which the execution flow is being executed at the moment.
    /// @param controllerToCheck The address of the controller for which it is checked whether it is an enabled controller for the account on behalf of which the execution flow is being executed at the moment.
    /// @return context Current execution context.
    /// @return controllerEnabled A boolean value that indicates whether controllerToCheck is an enabled controller for the account on behalf of which the execution flow is being executed at the moment. Always false if controllerToCheck passed is address(0).
    function getExecutionContext(
        address controllerToCheck
    )
        external
        view
        returns (ExecutionContext memory context, bool controllerEnabled)
    {
        context = executionContext;
        controllerEnabled = controllerToCheck == address(0)
            ? false
            : accountControllers[context.onBehalfOfAccount].contains(
                controllerToCheck
            );
    }

    /// @notice Checks whether the status check is deferred for a given account.
    /// @dev The account status check can only be deferred if the execution flow is currently in a batch.
    /// @param account The address of the account for which it is checked whether the status check is deferred.
    /// @return A boolean flag that indicates whether the status check is deferred or not.
    function isAccountStatusCheckDeferred(
        address account
    ) external view returns (bool) {
        return accountStatusChecks.contains(account);
    }

    /// @notice Checks whether the status check is deferred for a given vault.
    /// @dev The vault status check can only be deferred if the execution flow is currently in a batch.
    /// @param vault The address of the vault for which it is checked whether the status check is deferred.
    /// @return A boolean flag that indicates whether the status check is deferred or not.
    function isVaultStatusCheckDeferred(
        address vault
    ) external view returns (bool) {
        return vaultStatusChecks.contains(vault);
    }

    // Collaterals management

    /// @notice Returns an array of collaterals for an account.
    /// @dev A collateral is a vault for which account's balances are under the control of the currently chosen controller vault.
    /// @param account The address of the account whose collaterals are being queried.
    /// @return An array of addresses that are the collaterals for the account.
    function getCollaterals(
        address account
    ) external view returns (address[] memory) {
        return accountCollaterals[account].get();
    }

    /// @notice Returns whether a collateral is enabled for an account.
    /// @dev A collateral is a vault for which account's balances are under the control of the currently chosen controller vault.
    /// @param account The address of the account that is being checked.
    /// @param vault The address of the collateral that is being checked.
    /// @return A boolean value that indicates whether the vault is collateral for the account or not.
    function isCollateralEnabled(
        address account,
        address vault
    ) external view returns (bool) {
        return accountCollaterals[account].contains(vault);
    }

    /// @notice Enables a collateral for an account.
    /// @dev A collaterals is a vault for which account's balances are under the control of the currently chosen controller vault. Only the owner or an operator of the account can call this function. Account status checks are performed.
    /// @param account The address for which the collateral is being enabled.
    /// @param vault The address of the collateral being enabled.
    function enableCollateral(
        address account,
        address vault
    ) public payable virtual ownerOrOperator(account) nonReentrant {
        accountCollaterals[account].insert(vault);
        requireAccountStatusCheck(account);
    }

    /// @notice Disables a collateral for an account.
    /// @dev A collateral is a vault for which account’s balances are under the control of the currently chosen controller vault. Only the owner or an operator of the account can call this function. Account status checks are performed.
    /// @param account The address for which the collateral is being disabled.
    /// @param vault The address of the collateral being disabled.
    function disableCollateral(
        address account,
        address vault
    ) public payable virtual ownerOrOperator(account) nonReentrant {
        accountCollaterals[account].remove(vault);
        requireAccountStatusCheck(account);
    }

    // Controllers management

    /// @notice Returns an array of controllers for an account.
    /// @dev A controller is a vault that has been chosen for an account to have special control over account's balances in the collaterals vaults. A user can have multiple controllers within a batch execution, but only one (or none) can be selected when the account status check is performed upon the batch exit.
    /// @param account The address of the account whose controllers are being queried.
    /// @return An array of addresses that are the controllers for the account.
    function getControllers(
        address account
    ) external view returns (address[] memory) {
        return accountControllers[account].get();
    }

    /// @notice Returns whether a controller is enabled for an account.
    /// @dev A controller is a vault that has been chosen for an account to have special control over account’s balances in the collaterals vaults.
    /// @param account The address of the account that is being checked.
    /// @param vault The address of the controller that is being checked.
    /// @return A boolean value that indicates whether the vault is controller for the account or not.
    function isControllerEnabled(
        address account,
        address vault
    ) external view returns (bool) {
        return accountControllers[account].contains(vault);
    }

    /// @notice Enables a controller for an account.
    /// @dev A controller is a vault that has been chosen for an account to have special control over account’s balances in the collaterals vaults. Only the owner or an operator of the account can call this function. Account status checks are performed.
    /// @param account The address for which the controller is being enabled.
    /// @param vault The address of the controller being enabled.
    function enableController(
        address account,
        address vault
    ) public payable virtual ownerOrOperator(account) nonReentrant {
        if (accountControllers[account].insert(vault)) {
            emit ControllerEnabled(account, vault);
        }
        requireAccountStatusCheck(account);
    }

    /// @notice Disables a controller for an account.
    /// @dev A controller is a vault that has been chosen for an account to have special control over account’s balances in the collaterals vaults. Only the vault itself can call this function which means that msg.sender is treated as a calling vault. Account status checks are performed.
    /// @param account The address for which the calling controller is being disabled.
    function disableController(
        address account
    ) public payable virtual nonReentrant {
        if (accountControllers[account].remove(msg.sender)) {
            emit ControllerDisabled(account, msg.sender);
        }
        requireAccountStatusCheck(account);
    }

    // Call forwarding

    /// @notice Calls to a target contract as per data encoded.
    /// @dev This function can be used to interact with any contract. This function prevents sending ETH if it's called from a batch via delegatecall. If zero address passed as onBehalfOfAccount, msg.sender is used instead.
    /// @param targetContract The address of the contract to be called.
    /// @param onBehalfOfAccount The address of the account for which it is checked whether msg.sender is authorized to act on its behalf.
    /// @param data The encoded data which is called on the target contract.
    /// @return success A boolean value that indicates whether the call succeeded or not.
    /// @return result Returned data from the call.
    function call(
        address targetContract,
        address onBehalfOfAccount,
        bytes calldata data
    )
        public
        payable
        virtual
        nonReentrant
        returns (bool success, bytes memory result)
    {
        if (targetContract == address(this)) revert CVP_InvalidAddress();

        uint msgValue = executionContext.batchDepth == BATCH_DEPTH__INIT
            ? msg.value
            : 0;

        onBehalfOfAccount = onBehalfOfAccount == address(0)
            ? msg.sender
            : onBehalfOfAccount;

        (success, result) = callInternal(
            targetContract,
            onBehalfOfAccount,
            msgValue,
            data
        );
    }

    /// @notice Calls to one of the enabled collateral vaults from currently enabled controller vault for a given account.
    /// @dev This function can be used to interact with any vault if it is enabled as a collateral of the onBehalfOfAccount and the caller is the only controller of the onBehalfOfAccount. This function prevents sending ETH if it's called from a batch via delegatecall. If zero address passed as onBehalfOfAccount, msg.sender is used instead.
    /// @param targetContract The address of the contract to be called.
    /// @param onBehalfOfAccount The address of the account for which it is checked whether msg.sender is authorized to act on its behalf (impersonate)
    /// @param data The encoded data which is called on the target contract.
    /// @return success A boolean value that indicates whether the call succeeded or not.
    /// @return result Returned data from the call.
    function impersonate(
        address targetContract,
        address onBehalfOfAccount,
        bytes calldata data
    )
        public
        payable
        virtual
        nonReentrant
        returns (bool success, bytes memory result)
    {
        if (targetContract == address(this)) revert CVP_InvalidAddress();

        uint msgValue = executionContext.batchDepth == BATCH_DEPTH__INIT
            ? msg.value
            : 0;

        onBehalfOfAccount = onBehalfOfAccount == address(0)
            ? msg.sender
            : onBehalfOfAccount;

        (success, result) = impersonateInternal(
            targetContract,
            onBehalfOfAccount,
            msgValue,
            data
        );
    }

    // Batching

    /// @notice Defers the account and vault checks until the end of the execution flow and executes a batch of batch items.
    /// @dev Accounts status checks and vault status checks are performed after all the batch items have been executed. It's possible to have nested batches where checks are executed ony once after the top level batch concludes.
    /// @param items An array of batch items to be executed.
    function batch(
        BatchItem[] calldata items
    ) public payable virtual nonReentrant {
        uint batchDepthCache = executionContext.batchDepth;

        if (batchDepthCache >= BATCH_DEPTH__MAX) {
            revert CVP_BatchDepthViolation();
        }

        unchecked {
            ++executionContext.batchDepth;
        }

        batchInternal(items, false);

        unchecked {
            --executionContext.batchDepth;
        }

        if (batchDepthCache == BATCH_DEPTH__INIT) {
            executionContext.checksLock = true;
            checkStatusAll(SetType.Account, false);
            checkStatusAll(SetType.Vault, false);
            executionContext.checksLock = false;
        }
    }

    /// @notice Defers the account and vault checks until the end of the execution flow and executes a batch of batch items.
    /// @dev This function always reverts as it's only used for simulation purposes. Accounts status checks and vault status checks are performed after all the batch items have been executed.
    /// @param items An array of batch items to be executed.
    /// @return batchItemsResult An array of batch item results for each item.
    /// @return accountsStatusResult An array of account status results for each account.
    /// @return vaultsStatusResult An array of vault status results for each vault.
    function batchRevert(
        BatchItem[] calldata items
    )
        public
        payable
        virtual
        nonReentrant
        returns (
            BatchResult[] memory batchItemsResult,
            BatchResult[] memory accountsStatusResult,
            BatchResult[] memory vaultsStatusResult
        )
    {
        uint batchDepthCache = executionContext.batchDepth;

        if (batchDepthCache >= BATCH_DEPTH__MAX) {
            revert CVP_BatchDepthViolation();
        }

        unchecked {
            ++executionContext.batchDepth;
        }

        batchItemsResult = batchInternal(items, true);

        unchecked {
            --executionContext.batchDepth;
        }

        if (batchDepthCache == BATCH_DEPTH__INIT) {
            executionContext.checksLock = true;
            accountsStatusResult = checkStatusAll(SetType.Account, true);
            vaultsStatusResult = checkStatusAll(SetType.Vault, true);
            executionContext.checksLock = false;
        }

        revert CVP_RevertedBatchResult(
            batchItemsResult,
            accountsStatusResult,
            vaultsStatusResult
        );
    }

    function batchSimulation(
        BatchItem[] calldata items
    )
        public
        payable
        virtual
        returns (
            BatchResult[] memory batchItemsResult,
            BatchResult[] memory accountsStatusResult,
            BatchResult[] memory vaultsStatusResult
        )
    {
        (bool success, bytes memory result) = address(this).delegatecall(
            abi.encodeWithSelector(this.batchRevert.selector, items)
        );

        if (success) {
            revert CVP_BatchPanic();
        } else if (bytes4(result) != CVP_RevertedBatchResult.selector) {
            revertBytes(result);
        }

        assembly {
            result := add(result, 4)
        }

        (batchItemsResult, accountsStatusResult, vaultsStatusResult) = abi
            .decode(result, (BatchResult[], BatchResult[], BatchResult[]));
    }

    // Account Status Check

    /// @notice Checks the status of an account and returns whether it is valid or not.
    /// @dev Account status check is performed by calling into selected controller vault and passing the array of currently enabled collaterals. If controller is not selected, the account is considered valid.
    /// @param account The address of the account to be checked.
    /// @return isValid A boolean value that indicates whether the account is valid or not.
    function checkAccountStatus(
        address account
    ) public view returns (bool isValid) {
        (isValid, ) = checkAccountStatusInternal(account);
    }

    /// @notice Checks the status of multiple accounts and returns an array of boolean values that indicate whether each account is valid or not.
    /// @dev Account status check is performed by calling into selected controller vault and passing the array of currently enabled collaterals. If controller is not selected, the account is considered valid.
    /// @param accounts An array of addresses of the accounts to be checked.
    /// @return isValid An array of boolean values that indicate whether each account is valid or not.
    function checkAccountsStatus(
        address[] calldata accounts
    ) public view returns (bool[] memory isValid) {
        isValid = new bool[](accounts.length);

        uint length = accounts.length;
        for (uint i; i < length; ) {
            (isValid[i], ) = checkAccountStatusInternal(accounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Checks the status of an account and reverts if it is not valid.
    /// @dev If in a batch, the account is added to the set of accounts to be checked at the end of the execution flow. Account status check is performed by calling into selected controller vault and passing the array of currently enabled collaterals. If controller is not selected, the account is always considered valid. The account status is checked only if not explicitly ordered to be ignored for the current onBehalfOfAccount.
    /// @param account The address of the account to be checked.
    function requireAccountStatusCheck(address account) public virtual {
        if (executionContext.batchDepth == BATCH_DEPTH__INIT) {
            requireAccountStatusCheckInternal(account);
        } else {
            accountStatusChecks.insert(account);
        }
    }

    /// @notice Checks the status of multiple accounts and reverts if any of them is not valid.
    /// @dev If in a batch, the accounts are added to the set of accounts to be checked at the end of the execution flow. Account status check is performed by calling into selected controller vault and passing the array of currently enabled collaterals. If controller is not selected, the account is considered valid. The account status is checked only if not explicitly ordered to be ignored for the current onBehalfOfAccount.
    /// @param accounts An array of addresses of the accounts to be checked.
    function requireAccountsStatusCheck(
        address[] calldata accounts
    ) public virtual {
        uint batchDepthCache = executionContext.batchDepth;

        uint length = accounts.length;
        for (uint i; i < length; ) {
            if (batchDepthCache == BATCH_DEPTH__INIT) {
                requireAccountStatusCheckInternal(accounts[i]);
            } else {
                accountStatusChecks.insert(accounts[i]);
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Immediately checks the status of an account and reverts if it is not valid.
    /// @dev Account status check is performed on the fly regardless of the current execution context state. If account was previously added to a set to be checked later, it is removed.
    /// @param account The address of the account to be checked.
    function requireAccountStatusCheckNow(address account) public virtual {
        requireAccountStatusCheckInternal(account);
        accountStatusChecks.remove(account);
    }

    /// @notice Immediately checks the status of multiple accounts and reverts if any of them is not valid.
    /// @dev Account status checks are performed on the fly regardless of the current execution context state. If account was previously added to a set to be checked later, it is removed.
    /// @param accounts An array of addresses of the accounts to be checked.
    function requireAccountsStatusCheckNow(
        address[] calldata accounts
    ) public virtual {
        uint length = accounts.length;
        for (uint i; i < length; ) {
            address account = accounts[i];
            requireAccountStatusCheckInternal(account);
            accountStatusChecks.remove(account);

            unchecked {
                ++i;
            }
        }
    }

    function forgiveAccountStatusCheck(
        address account
    ) public virtual authenticateController(account) {
        accountStatusChecks.remove(account);
    }

    function forgiveAccountsStatusCheck(
        address[] calldata accounts
    ) public virtual {
        uint length = accounts.length;
        for (uint i; i < length; ) {
            address account = accounts[i];
            uint numOfControllers = accountControllers[account].numElements;
            address controller = accountControllers[account].firstElement;

            if (numOfControllers != 1) revert CVP_ControllerViolation();
            else if (controller != msg.sender) revert CVP_NotAuthorized();

            accountStatusChecks.remove(account);

            unchecked {
                ++i;
            }
        }
    }

    // Vault Status Check

    /// @notice Checks the status of a vault and reverts if it is not valid.
    /// @dev If in a batch, the vault is added to the set of vaults to be checked at the end of the execution flow. This function can only be called by the vault itself.
    function requireVaultStatusCheck() public virtual {
        if (executionContext.batchDepth == BATCH_DEPTH__INIT) {
            requireVaultStatusCheckInternal(msg.sender);
        } else {
            vaultStatusChecks.insert(msg.sender);
        }
    }

    function forgiveVaultStatusCheck() external {
        vaultStatusChecks.remove(msg.sender);
    }

    // INTERNAL FUNCTIONS

    function callInternal(
        address targetContract,
        address onBehalfOfAccount,
        uint msgValue,
        bytes calldata data
    )
        internal
        virtual
        ownerOrOperator(onBehalfOfAccount)
        onBehalfOfAccountContext(onBehalfOfAccount)
        returns (bool success, bytes memory result)
    {
        if (targetContract == ERC1820_REGISTRY) revert CVP_InvalidAddress();

        msgValue = msgValue == type(uint).max
            ? address(this).balance
            : msgValue;

        (success, result) = targetContract.call{value: msgValue}(data);
    }

    function impersonateInternal(
        address targetContract,
        address onBehalfOfAccount,
        uint msgValue,
        bytes calldata data
    )
        internal
        authenticateController(onBehalfOfAccount)
        onBehalfOfAccountContext(onBehalfOfAccount)
        returns (bool success, bytes memory result)
    {
        if (!accountCollaterals[onBehalfOfAccount].contains(targetContract)) {
            revert CVP_NotAuthorized();
        }

        executionContext.impersonateLock = true;

        (success, result) = targetContract.call{value: msgValue}(data);

        executionContext.impersonateLock = false;
    }

    function batchInternal(
        BatchItem[] calldata items,
        bool returnResult
    ) internal returns (BatchResult[] memory batchItemsResult) {
        if (returnResult) batchItemsResult = new BatchResult[](items.length);

        uint length = items.length;
        for (uint i; i < length; ) {
            BatchItem calldata item = items[i];
            address targetContract = item.targetContract;
            bool success;
            bytes memory result;

            if (targetContract == address(this)) {
                (success, result) = address(this).delegatecall(item.data);
            } else {
                address onBehalfOfAccount = item.onBehalfOfAccount == address(0)
                    ? msg.sender
                    : item.onBehalfOfAccount;

                (success, result) = callInternal(
                    targetContract,
                    onBehalfOfAccount,
                    item.msgValue,
                    item.data
                );
            }

            if (returnResult) {
                batchItemsResult[i].success = success;
                batchItemsResult[i].result = result;
            } else if (!(success || item.allowError)) {
                revertBytes(result);
            }

            unchecked {
                ++i;
            }
        }
    }

    function checkAccountStatusInternal(
        address account
    ) internal view returns (bool isValid, bytes memory data) {
        uint numOfControllers = accountControllers[account].numElements;
        address controller = accountControllers[account].firstElement;

        if (numOfControllers == 0) return (true, "");
        else if (numOfControllers > 1) revert CVP_ControllerViolation();

        bool success;
        (success, data) = controller.staticcall(
            abi.encodeWithSelector(
                ICreditVault.checkAccountStatus.selector,
                account,
                accountCollaterals[account].get()
            )
        );

        if (success) (isValid, data) = abi.decode(data, (bool, bytes));
    }

    function requireAccountStatusCheckInternal(
        address account
    ) internal virtual {
        (bool isValid, bytes memory data) = checkAccountStatusInternal(account);

        if (!isValid) revert CVP_AccountStatusViolation(account, data);
    }

    function checkVaultStatusInternal(
        address vault
    ) internal returns (bool isValid, bytes memory data) {
        bool success;
        (success, data) = vault.call(
            abi.encodeWithSelector(ICreditVault.checkVaultStatus.selector)
        );

        if (success) (isValid, data) = abi.decode(data, (bool, bytes));
    }

    function requireVaultStatusCheckInternal(address vault) internal virtual {
        (bool isValid, bytes memory data) = checkVaultStatusInternal(vault);

        if (!isValid) revert CVP_VaultStatusViolation(vault, data);
    }

    function checkStatusAll(
        SetType setType,
        bool returnResult
    ) private returns (BatchResult[] memory result) {
        function(address) returns (bool, bytes memory) checkStatus;
        function(address) requireStatusCheck;
        SetStorage storage setStorage;

        if (setType == SetType.Account) {
            checkStatus = checkAccountStatusInternal;
            requireStatusCheck = requireAccountStatusCheckInternal;
            setStorage = accountStatusChecks;
        } else {
            checkStatus = checkVaultStatusInternal;
            requireStatusCheck = requireVaultStatusCheckInternal;
            setStorage = vaultStatusChecks;
        }

        uint numElements = setStorage.numElements;
        address firstElement = setStorage.firstElement;

        if (returnResult) result = new BatchResult[](numElements);

        if (numElements == 0) return result;

        // clear only the number of elements to optimize gas consumption
        if (setType == SetType.Account) accountStatusChecks.numElements = 0;
        else vaultStatusChecks.numElements = 0;

        for (uint i; i < numElements; ) {
            address addressToCheck = i == 0
                ? firstElement
                : setStorage.elements[i];

            if (returnResult) {
                bytes memory data;
                (result[i].success, data) = checkStatus(addressToCheck);

                if (!result[i].success) {
                    bytes4 violationSelector = setType == SetType.Account
                        ? CVP_AccountStatusViolation.selector
                        : CVP_VaultStatusViolation.selector;

                    result[i].result = abi.encodeWithSelector(
                        violationSelector,
                        addressToCheck,
                        data
                    );
                }
            } else {
                requireStatusCheck(addressToCheck);
            }

            unchecked {
                ++i;
            }
        }
    }

    // Error handling

    function revertBytes(bytes memory errMsg) internal pure {
        if (errMsg.length != 0) {
            assembly {
                revert(add(32, errMsg), mload(errMsg))
            }
        }
        revert("CVP-empty-error");
    }

    // Formal verification

    function invariantsCheck() public view {
        ExecutionContext memory context = executionContext;
        assert(context.batchDepth == BATCH_DEPTH__INIT);
        assert(!context.checksLock);
        assert(!context.impersonateLock);
        assert(context.onBehalfOfAccount == address(0));
        assert(accountStatusChecks.numElements == 0);
        assert(vaultStatusChecks.numElements == 0);
    }
}