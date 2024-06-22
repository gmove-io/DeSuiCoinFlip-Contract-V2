import { Transaction } from '@mysten/sui/transactions';
import { client, keyPair, SUI_HOUSE } from './utils';
import { randomBytes } from '@noble/hashes/utils';
import invariant from 'tiny-invariant';
import { SUI_TYPE_ARG } from '@mysten/sui/utils';
import { bcs } from '@mysten/sui/bcs';
import { SerialTransactionExecutor } from '@mysten/sui/transactions';

const packageId =
  '0x3e440a9e534adc0e81144f7045769776b2c808b7549557b0e683a4cb8b65c341';

invariant(packageId, 'Missing package id');

const PAY_AMOUNTS = Array(200).fill(2);
const NUMBER_OF_TXS = Array(2).fill(0);

const play = () => {
  const tx = new Transaction();

  tx.setSender(keyPair.toSuiAddress());
  tx.setGasBudget(2_000_000_000n);
  tx.setGasPrice(2_000n);

  const payments = tx.splitCoins(
    tx.gas,
    PAY_AMOUNTS.map((x) => tx.pure.u64(x))
  );

  for (const [i] of PAY_AMOUNTS.entries()) {
    tx.moveCall({
      target: `${packageId}::coin_flip_v2::start_game`,
      typeArguments: [SUI_TYPE_ARG],
      arguments: [
        tx.object(SUI_HOUSE),
        tx.pure.u8(0),
        tx.pure(bcs.vector(bcs.u8()).serialize(Array.from(randomBytes(512)))),
        payments[i],
      ],
    });
  }

  return tx;
};

const singlePlay = async () => {
  const now = new Date().getTime() / 1000;
  const tx = new Transaction();

  const payments = tx.splitCoins(tx.gas, [tx.pure.u64(2)]);
  tx.setSender(keyPair.toSuiAddress());
  tx.setGasBudget(2_000_000_000n);
  tx.setGasPrice(2_000n);

  tx.moveCall({
    target: `${packageId}::coin_flip_v2::start_game`,
    typeArguments: [SUI_TYPE_ARG],
    arguments: [
      tx.object(SUI_HOUSE),
      tx.pure.u8(0),
      tx.pure(bcs.vector(bcs.u8()).serialize(Array.from(randomBytes(512)))),
      payments,
    ],
  });

  const result = await client.signAndExecuteTransaction({
    signer: keyPair,
    transaction: tx,
    options: {
      showEffects: true,
    },
    requestType: 'WaitForLocalExecution',
  });

  invariant(result.effects?.status.status === 'success');

  const delay = new Date().getTime() / 1000 - now;

  console.log(`It took ${delay} to submit 1 TX`);
};

const submitWithSerialExecutor = async () => {
  const now = new Date().getTime() / 1000;

  const executor = new SerialTransactionExecutor({
    client,
    signer: keyPair,
  });

  await Promise.all(
    NUMBER_OF_TXS.map(() => executor.executeTransaction(play()))
  );

  const delay = new Date().getTime() / 1000 - now;

  console.log(`It took ${delay} with the Serial Executor to process 3 TXs`);
};

(async () => {
  try {
    await submitWithSerialExecutor();
    await singlePlay();
  } catch (e) {
    console.log(e);
  }
})();
