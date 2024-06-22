import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import dotenv from 'dotenv';
import * as fs from 'fs';
import util from 'util';
import { Inputs } from '@mysten/sui/transactions';

dotenv.config();

export interface IObjectInfo {
  type: string | undefined;
  id: string | undefined;
}

export const keyPair = Ed25519Keypair.fromSecretKey(
  Uint8Array.from(Buffer.from(process.env.KEY!, 'base64')).slice(1)
);

export const client = new SuiClient({ url: getFullnodeUrl('testnet') });

export const getId = (type: string): string | undefined => {
  try {
    const rawData = fs.readFileSync('../dsl.json', 'utf8');
    const parsedData: IObjectInfo[] = JSON.parse(rawData);
    const typeToId = new Map(parsedData.map((item) => [item.type, item.id]));
    return typeToId.get(type);
  } catch (error) {
    console.error('Error reading the DSL file:', error);
  }
};

export const log = (x: unknown) =>
  console.log(
    util.inspect(x, { showHidden: false, depth: null, colors: true })
  );

export const SUI_HOUSE = Inputs.SharedObjectRef({
  objectId:
    '0xe93f24d67b2520271468d44d2436da5108730cfd5a992197e63b90f895aba90e',
  mutable: true,
  initialSharedVersion: '56426400',
});
