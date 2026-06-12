package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"flag"
	"fmt"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/holiman/uint256"
)

const gasPriceOracleAddress = "0x420000000000000000000000000000000000000F"

var magicReturn = common.Hex2Bytes("7702770277027702770277027702770277027702770277027702770277027702")

func main() {
	var (
		rpcURL         = flag.String("rpc", "http://localhost:8645", "L2 RPC URL")
		payerKeyHex    = flag.String("payer-private-key", "", "private key that pays for L2 transactions")
		delegateInput  = flag.String("delegate-address", "", "optional existing delegate contract address; if empty, EIP7702Delegate bytecode is deployed")
		delegateCode   = flag.String("delegate-bytecode", "", "delegate contract creation bytecode; required if delegate-address is empty")
		requireIsthmus = flag.Bool("require-isthmus", true, "require GasPriceOracle.isIsthmus() to be true")
		requireJovian  = flag.Bool("require-jovian", true, "require GasPriceOracle.isJovian() to be true")
	)
	flag.Parse()

	if *payerKeyHex == "" {
		fail("missing --payer-private-key")
	}

	ctx := context.Background()
	client, err := ethclient.Dial(*rpcURL)
	check(err, "connect L2 RPC")
	defer client.Close()

	payerKey := mustPrivateKey(*payerKeyHex)
	payer := crypto.PubkeyToAddress(payerKey.PublicKey)

	chainID, err := client.ChainID(ctx)
	check(err, "read chain ID")

	fmt.Println("============================================")
	fmt.Println("  EIP-7702 Verification")
	fmt.Println("============================================")
	fmt.Printf("L2 RPC:       %s\n", *rpcURL)
	fmt.Printf("chainID:      %s\n", chainID)
	fmt.Printf("payer:        %s\n", payer)
	fmt.Println("")

	checkForkFlag(ctx, client, "isIsthmus()", *requireIsthmus)
	checkForkFlag(ctx, client, "isJovian()", *requireJovian)
	fmt.Println("")

	gasTipCap, gasFeeCap := suggestFees(ctx, client)

	var delegate common.Address
	if *delegateInput == "" {
		if *delegateCode == "" {
			fail("missing --delegate-bytecode when --delegate-address is not provided")
		}
		delegate = deployDelegate(ctx, client, payerKey, chainID, payer, gasTipCap, gasFeeCap, common.FromHex(*delegateCode))
	} else {
		delegate = common.HexToAddress(*delegateInput)
		code, err := client.CodeAt(ctx, delegate, nil)
		check(err, "read delegate code")
		if len(code) == 0 {
			fail("delegate address has no code: %s", delegate)
		}
		fmt.Printf("using delegate contract: %s\n", delegate)
	}

	authorityKey, err := ecdsa.GenerateKey(crypto.S256(), rand.Reader)
	check(err, "generate authority key")
	authority := crypto.PubkeyToAddress(authorityKey.PublicKey)

	sendSetCodeTx(ctx, client, payerKey, authorityKey, chainID, payer, authority, delegate, gasTipCap, gasFeeCap)
	verifyDelegationCode(ctx, client, authority, delegate)
	verifyDelegatedExecution(ctx, client, payer, authority)

	fmt.Println("")
	fmt.Println("OK: EIP-7702 SetCodeTx succeeded, delegation code was installed, and delegated execution returned expected data.")
}

func checkForkFlag(ctx context.Context, client *ethclient.Client, method string, required bool) {
	selector := crypto.Keccak256([]byte(method))[:4]
	to := common.HexToAddress(gasPriceOracleAddress)
	out, err := client.CallContract(ctx, ethereum.CallMsg{
		To:   &to,
		Data: selector,
	}, nil)
	if err != nil {
		if required {
			fail("%s call failed: %v", method, err)
		}
		fmt.Printf("%s: unavailable (%v)\n", method, err)
		return
	}
	value := len(out) >= 32 && out[len(out)-1] == 1
	fmt.Printf("%s: %t\n", method, value)
	if required && !value {
		fail("%s is false; fork is not active enough for this verification", method)
	}
}

func deployDelegate(ctx context.Context, client *ethclient.Client, payerKey *ecdsa.PrivateKey, chainID *big.Int, payer common.Address, gasTipCap, gasFeeCap *big.Int, creationCode []byte) common.Address {
	nonce, err := client.PendingNonceAt(ctx, payer)
	check(err, "read payer nonce for delegate deployment")

	if len(creationCode) == 0 {
		fail("delegate creation bytecode is empty")
	}

	tx := types.MustSignNewTx(payerKey, types.LatestSignerForChainID(chainID), &types.DynamicFeeTx{
		ChainID:   chainID,
		Nonce:     nonce,
		GasTipCap: gasTipCap,
		GasFeeCap: gasFeeCap,
		Gas:       200000,
		Data:      creationCode,
	})

	check(client.SendTransaction(ctx, tx), "send delegate deployment tx")
	fmt.Printf("delegate deploy tx: %s\n", tx.Hash())

	receipt := waitReceipt(ctx, client, tx.Hash())
	if receipt.Status != types.ReceiptStatusSuccessful {
		fail("delegate deployment failed with receipt status %d", receipt.Status)
	}
	if receipt.ContractAddress == (common.Address{}) {
		fail("delegate deployment returned empty contract address")
	}
	fmt.Printf("delegate contract:  %s\n", receipt.ContractAddress)
	return receipt.ContractAddress
}

func sendSetCodeTx(ctx context.Context, client *ethclient.Client, payerKey, authorityKey *ecdsa.PrivateKey, chainID *big.Int, payer, authority, delegate common.Address, gasTipCap, gasFeeCap *big.Int) {
	payerNonce, err := client.PendingNonceAt(ctx, payer)
	check(err, "read payer nonce for SetCodeTx")
	authorityNonce, err := client.PendingNonceAt(ctx, authority)
	check(err, "read authority nonce")

	auth, err := types.SignSetCode(authorityKey, types.SetCodeAuthorization{
		ChainID: *uint256.MustFromBig(chainID),
		Address: delegate,
		Nonce:   authorityNonce,
	})
	check(err, "sign set-code authorization")

	tx := types.MustSignNewTx(payerKey, types.LatestSignerForChainID(chainID), &types.SetCodeTx{
		ChainID:   uint256.MustFromBig(chainID),
		Nonce:     payerNonce,
		GasTipCap: uint256.MustFromBig(gasTipCap),
		GasFeeCap: uint256.MustFromBig(gasFeeCap),
		Gas:       120000,
		To:        authority,
		Value:     uint256.NewInt(0),
		AuthList:  []types.SetCodeAuthorization{auth},
	})

	check(client.SendTransaction(ctx, tx), "send EIP-7702 SetCodeTx")
	fmt.Printf("authority:          %s\n", authority)
	fmt.Printf("authority nonce:    %d\n", authorityNonce)
	fmt.Printf("set-code tx:        %s\n", tx.Hash())

	receipt := waitReceipt(ctx, client, tx.Hash())
	if receipt.Status != types.ReceiptStatusSuccessful {
		fail("SetCodeTx failed with receipt status %d", receipt.Status)
	}
	fmt.Printf("set-code block:     %d\n", receipt.BlockNumber.Uint64())
	fmt.Printf("set-code gas used:  %d\n", receipt.GasUsed)
}

func verifyDelegationCode(ctx context.Context, client *ethclient.Client, authority, delegate common.Address) {
	code, err := client.CodeAt(ctx, authority, nil)
	check(err, "read authority code")
	want := types.AddressToDelegation(delegate)
	if !bytes.Equal(code, want) {
		fail("unexpected authority code: got 0x%x want 0x%x", code, want)
	}
	fmt.Printf("authority code:     0x%x\n", code)
}

func verifyDelegatedExecution(ctx context.Context, client *ethclient.Client, payer, authority common.Address) {
	out, err := client.CallContract(ctx, ethereum.CallMsg{
		From: payer,
		To:   &authority,
	}, nil)
	check(err, "call authority delegated code")
	if !bytes.Equal(out, magicReturn) {
		fail("unexpected delegated call return: got 0x%x want 0x%x", out, magicReturn)
	}
	fmt.Printf("delegated return:   0x%x\n", out)
}

func waitReceipt(ctx context.Context, client *ethclient.Client, hash common.Hash) *types.Receipt {
	for i := 0; i < 60; i++ {
		receipt, err := client.TransactionReceipt(ctx, hash)
		if err == nil && receipt != nil {
			return receipt
		}
		time.Sleep(time.Second)
	}
	fail("transaction %s was not confirmed within 60s", hash)
	return nil
}

func suggestFees(ctx context.Context, client *ethclient.Client) (*big.Int, *big.Int) {
	gasPrice, err := client.SuggestGasPrice(ctx)
	check(err, "suggest gas price")
	gasTipCap, err := client.SuggestGasTipCap(ctx)
	if err != nil {
		gasTipCap = big.NewInt(0)
	}
	gasFeeCap := new(big.Int).Mul(gasPrice, big.NewInt(2))
	if gasFeeCap.Cmp(gasTipCap) < 0 {
		gasFeeCap = new(big.Int).Set(gasTipCap)
	}
	return gasTipCap, gasFeeCap
}

func mustPrivateKey(hexKey string) *ecdsa.PrivateKey {
	hexKey = strings.TrimPrefix(hexKey, "0x")
	key, err := crypto.HexToECDSA(hexKey)
	check(err, "parse private key")
	return key
}

func check(err error, context string) {
	if err != nil {
		fail("%s: %v", context, err)
	}
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "ERROR: "+format+"\n", args...)
	os.Exit(1)
}
