import { OwnedObjectRef } from '@mysten/sui/client';
import { bcs } from '@mysten/sui/bcs';
import { SUI_TYPE_ARG } from '@mysten/sui/utils';
import { Transaction } from '@mysten/sui/transactions';
import { client, IObjectInfo, keyPair, getId } from './utils';
import invariant from 'tiny-invariant';
import { generateBls12381G2KeyPair } from '@mattrglobal/bbs-signatures';

const packageId = getId('package');
const admin = getId('coin_flip_v2::AdminCap');

invariant(admin, 'Missing admin cap');
invariant(packageId, 'Missing package id');

(async () => {
  try {
    const tx = new Transaction();

    const initialCoin = tx.splitCoins(tx.gas, [tx.pure.u64(100000)]);

    const blsKeyPair = await generateBls12381G2KeyPair();

    tx.moveCall({
      target: `${packageId}::coin_flip_v2::create_house`,
      typeArguments: [SUI_TYPE_ARG],
      arguments: [
        tx.object(admin),
        tx.pure(
          bcs.vector(bcs.u8()).serialize(Array.from(blsKeyPair.publicKey))
        ),
        tx.pure.u128(2000),
        tx.pure.u64(1),
        tx.pure.u64(10),
        initialCoin,
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

    console.log(result);

    // return if the tx hasn't succeed
    if (result.effects?.status?.status !== 'success') {
      console.log('\n\nPublishing failed');
      return;
    }

    // get all created objects IDs
    const createdObjectIds = result.effects.created!.map(
      (item: OwnedObjectRef) => item.reference.objectId
    );

    // fetch objects data
    const createdObjects = await client.multiGetObjects({
      ids: createdObjectIds,
      options: { showContent: true, showType: true, showOwner: true },
    });

    const objects: IObjectInfo[] = [];
    createdObjects.forEach((item) => {
      if (item.data?.type === 'package') {
        objects.push({
          type: 'package',
          id: item.data?.objectId,
        });
      } else if (!item.data!.type!.includes('SUI')) {
        objects.push({
          type: item.data?.type!.slice(68),
          id: item.data?.objectId,
        });
      }
    });

    console.log({ objects });
  } catch (e) {
    console.log(e);
  }
})();
