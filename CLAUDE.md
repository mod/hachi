# CLAUDE.md - Foundry/Solidity State Channel Project Guidelines

## Commands
- Build: `forge build`
- Test all: `forge test`
- Test single: `forge test --match-test test_FunctionName`
- Test specific file: `forge test --match-path test/adjudicators/MicroPayment.t.sol`
- Test with verbosity: `forge test -vv` (show logs), `-vvv` (show traces)
- Coverage: `forge coverage`
- Format: `forge fmt`
- Gas analysis: `forge snapshot`
- Local node: `anvil`
- Deploy: `forge script script/ScriptName.s.sol:ContractScript --rpc-url <url> --private-key <key>`
- Lint: `solhint "src/**/*.sol"` (if installed)
- Clean: `forge clean`
- Debug: `forge test --debug test_FunctionName`

## Code Style
- SPDX license headers required (MIT license)
- Pragma: `^0.8.13` or higher
- Imports: Use named imports `import {Contract} from "path/to/Contract.sol"`
- Contract organization: errors > structs > state variables > events > modifiers > constructor > external > public > internal > private
- Function naming: camelCase (e.g., `adjudicate`, `verifySignature`)
- Variable naming: private/internal prefixed with underscore (e.g., `_balance`)
- Test naming: standard tests `test_FunctionName` (use underscores)
- Error handling: Use custom errors (`error InvalidSignature();`) instead of revert strings
- NatSpec comments: Required for all public/external functions, structs, and interfaces
- State channel specific: Follow the types defined in `Types.sol`
- Max line length: 120 characters
- Security: Explicit visibility for all functions and state variables
- Signatures: Use `stateHash = keccak256(data)` pattern and `ecrecover` for verification