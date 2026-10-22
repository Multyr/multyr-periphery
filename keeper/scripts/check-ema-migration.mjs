// Read-only cutover guard. Run before deploying the release keeper configuration.
import fs from 'node:fs';
import {createPublicClient,http,parseAbi} from 'viem';
const path=new URL('../config/arbitrum-one.ema-first-20261023.json',import.meta.url);
const config=JSON.parse(fs.readFileSync(path,'utf8'));
const release=JSON.parse(fs.readFileSync(new URL('../deploy/aws/ema-first-20261023.json',import.meta.url),'utf8'));
const client=createPublicClient({transport:http(process.env.RPC_URL || 'https://arb1.arbitrum.io/rpc')});
const blockNumber=await client.getBlockNumber();
const read=(address,signature,args=[])=>client.readContract({address,abi:parseAbi(['function '+signature]),functionName:signature.split('(')[0],args,blockNumber});
if(await client.getChainId()!==42161)throw Error('Wrong chain');
if(!await read(release.router,'isStrategyEnabled(address) view returns(bool)',[config.addresses.strategyVault]))throw Error('Safe migration not executed: replacement strategy inactive');
if(await read(release.router,'isStrategyEnabled(address) view returns(bool)',[release.previousStrategy]))throw Error('Old strategy still active');
if(await read(release.previousUpkeep,'enabled(address) view returns(bool)',[release.previousStrategy]))throw Error('Old upkeep still enabled');
if(!await read(config.addresses.strategyUpkeep,'enabled(address) view returns(bool)',[config.addresses.strategyVault]))throw Error('New upkeep disabled');
if((await read(config.addresses.strategyVault,'rebalanceGasEstimator() view returns(address)')).toLowerCase()!==release.estimator.toLowerCase())throw Error('Estimator mismatch');
if(Number(await read(config.addresses.strategyVault,'targetIdleBufferBps() view returns(uint16)'))!==1000)throw Error('Reserve mismatch');
console.log(JSON.stringify({status:'migration-complete',blockNumber:String(blockNumber),strategy:config.addresses.strategyVault,upkeep:config.addresses.strategyUpkeep}));
