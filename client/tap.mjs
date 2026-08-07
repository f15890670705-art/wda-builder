#!/usr/bin/env node
// tap.mjs — AilinTouch 控制端（零依赖 Node 脚本）
// 用法:
//   node tap.mjs <ip> tap 100 200
//   node tap.mjs <ip> swipe 100 200 300 400 500
//   node tap.mjs <ip> key 40        (usage: 40=Enter, 44=Space, 4-29=a-z)
//   node tap.mjs <ip> status

const [,, ip, cmd, ...args] = process.argv;
if (!ip || !cmd) {
  console.log('用法: node tap.mjs <ip> <tap|swipe|key|status> [...]');
  process.exit(1);
}

const port = 8080;
const get = (path) => fetch(`http://${ip}:${port}${path}`).then(r => r.json());

switch (cmd) {
  case 'tap': {
    const [x, y] = args.map(Number);
    console.log(await get(`/tap?x=${x}&y=${y}`));
    break;
  }
  case 'swipe': {
    const [x1, y1, x2, y2, ms = 300] = args.map(Number);
    console.log(await get(`/swipe?x1=${x1}&y1=${y1}&x2=${x2}&y2=${y2}&ms=${ms}`));
    break;
  }
  case 'key': {
    const usage = Number(args[0]);
    console.log(await get(`/key?usage=${usage}`));
    break;
  }
  case 'status':
    console.log(await get('/status'));
    break;
  default:
    console.log('未知命令:', cmd);
}
