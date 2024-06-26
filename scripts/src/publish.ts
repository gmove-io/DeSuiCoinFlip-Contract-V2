import { OwnedObjectRef } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import * as fs from 'fs';
import { execSync } from 'child_process';
import { client, getId, IObjectInfo, keyPair } from './utils';

(async () => {
  console.log('building package...');

  const { modules, dependencies } = JSON.parse(
    execSync(
      `${process.env.CLI_PATH!} move build --dump-bytecode-as-base64 --path ${process.env.PACKAGE_PATH!}`,
      {
        encoding: 'utf-8',
      }
    )
  );

  console.log('publishing...');

  try {
    const tx = new Transaction();
    const [upgradeCap] = tx.publish({ modules, dependencies });
    tx.transferObjects([upgradeCap], keyPair.getPublicKey().toSuiAddress());

    const result = await client.signAndExecuteTransaction({
      signer: keyPair,
      transaction: tx,
      options: {
        showEffects: true,
      },
      requestType: 'WaitForLocalExecution',
    });

    console.log('result: ', JSON.stringify(result, null, 2));

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

    fs.writeFileSync('../dsl.json', JSON.stringify(objects, null, 2));
  } catch (e) {
    console.log(e);
  } finally {
    console.log('\n\nSuccessfully deployed at: ' + getId('package'));
  }
})();
