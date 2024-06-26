import { Transaction } from '@mysten/sui/transactions';
import { client, keyPair, log } from './utils';
import { SUI_TYPE_ARG } from '@mysten/sui/utils';

(async () => {
  try {
    const tx = new Transaction();

    const coin = tx.splitCoins(tx.gas, [tx.pure.u64(0)]);

    tx.moveCall({
      target: '0x2::coin::destroy_zero',
      typeArguments: [SUI_TYPE_ARG],
      arguments: [coin],
    });

    const result = await client.signAndExecuteTransaction({
      signer: keyPair,
      transaction: tx,
      options: {
        showEffects: true,
      },
      requestType: 'WaitForLocalExecution',
    });
    log(result);
  } catch (e) {
    console.log(e);
  }
})();
