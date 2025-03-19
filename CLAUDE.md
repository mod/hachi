# CLAUDE.md - Foundry/Solidity State Channel Project Guidelines

## Commands
- Build: `forge build`
- Test all: `forge test`
- Test single: `forge test --match-test testFunctionName`
- Test with verbosity: `forge test -vv` (show logs), `-vvv` (show traces)
- Format: `forge fmt`
- Gas analysis: `forge snapshot`
- Local node: `anvil`
- Deploy: `forge script script/ScriptName.s.sol:ContractScript --rpc-url <url> --private-key <key>`
- Lint: `solhint "src/**/*.sol"` (if installed)

## Code Style
- SPDX license headers required (MIT license)
- Pragma: `^0.8.13` or higher
- Imports: Use named imports `import {Contract} from "path/to/Contract.sol"`
- Contract organization: interfaces > state variables > events > modifiers > constructor > external > public > internal > private
- Function naming: camelCase (e.g., `adjudicate`, `verifySignature`)
- Test naming: standard tests `test_FunctionName`, fuzz tests `testFuzz_FunctionName`
- Error handling: Use custom errors (`error InvalidSignature();`) instead of revert strings
- NatSpec comments for all public/external functions and interfaces
- State channel specific: Follow the types defined in ITypes.sol
- Max line length: 120 characters