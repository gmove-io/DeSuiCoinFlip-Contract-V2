import { Transaction } from '@mysten/sui/transactions';
import { client, keyPair, getId, SUI_HOUSE } from './utils';
import { randomBytes } from '@noble/hashes/utils';
import invariant from 'tiny-invariant';
import { SUI_TYPE_ARG } from '@mysten/sui/utils';
import { bcs } from '@mysten/sui/bcs';
import { ParallelTransactionExecutor } from '@mysten/sui/transactions';

const packageId = getId('package');

invariant(packageId, 'Missing package id');

const PAY_AMOUNTS = Array(200).fill(2);
const NUMBER_OF_TXS = Array(25).fill(0);

const play = () => {
  const tx = new Transaction();

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

(async () => {
  try {
    const now = new Date().getTime() / 1000;
    const executor = new ParallelTransactionExecutor({
      client,
      signer: keyPair,
      initialCoinBalance: 4000000000n,
      minimumCoinBalance: 2000000000n,
    });

    const results = await Promise.all(
      NUMBER_OF_TXS.map(() => executor.executeTransaction(play()))
    );

    console.log(new Date().getTime() / 1000 - now);

    console.log(results.length);
  } catch (e) {
    console.log(e);
  }
})();
