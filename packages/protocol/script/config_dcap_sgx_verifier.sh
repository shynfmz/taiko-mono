PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
PROPOSER=0x0000000000000000000000000000000000000000 \
PROPOSER_ONE=0x0000000000000000000000000000000000000000 \
GUARDIAN_PROVERS="0x1000777700000000000000000000000000000001,0x1000777700000000000000000000000000000002,0x1000777700000000000000000000000000000003,0x1000777700000000000000000000000000000004,0x1000777700000000000000000000000000000005" \
MIN_GUARDIANS=3 \
TAIKO_L2_ADDRESS=0x1000777700000000000000000000000000000001 \
L2_SIGNAL_SERVICE=0x1000777700000000000000000000000000000007 \
SECURITY_COUNCIL=0x60997970C51812dc3A010C7d01b50e0d17dc79C8 \
TAIKO_TOKEN_PREMINT_RECIPIENT=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720 \
TAIKO_TOKEN_NAME="Taiko Token Katla" \
TAIKO_TOKEN_SYMBOL=TTKOk \
SHARED_ADDRESS_MANAGER=0x0000000000000000000000000000000000000000 \
L2_GENESIS_HASH=0xee1950562d42f0da28bd4550d88886bc90894c77c9c9eaefef775d4c8223f259 \
ETHERSCAN_API_KEY=ABC123ABC123ABC123ABC123ABC123ABC1 \
LOG_LEVEL=DEBUG \
REPORT_GAS=true \
SGX_VERIFIER_ADDRESS=0x1fA02b2d6A771842690194Cf62D91bdd92BfE28d \
TIMELOCK_ADDRESS=0xB2b580ce436E6F77A5713D80887e14788Ef49c9A \
ATTESTATION_ADDRESS=0xC9a43158891282A2B1475592D5719c001986Aaec \
TCB_INFO_PATH=/test/onchainRA/assets/0923/tcbInfo.json \
QEID_PATH=/test/onchainRA/assets/0923/identity.json \
V3_QUOTE_PATH=/test/onchainRA/assets/0923/v3quote.json \
MR_ENCLAVE=0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
MR_SIGNER=0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
forge script script/SetDcapParams.s.sol:SetDcapParams \
    --fork-url http://localhost:8545 \
    --broadcast \
    --ffi \
    -vvvv \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    --block-gas-limit 100000000