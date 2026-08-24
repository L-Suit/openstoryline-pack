#!/usr/bin/env python3
"""
fetch_wheels.py — 根据 pip --report 生成的 JSON 清单，用 curl 断点续传下载所有 wheel。
用于代理出口不稳定时替代 pip 的在线下载（pip 长连接易断，curl -C - 可续传）。

用法:
  python3 scripts/fetch_wheels.py <report.json> <输出目录> [--exclude 前缀 ...]
下载完成后再离线安装:
  pip install --no-index --find-links <输出目录> -r requirements.txt
"""
import json, os, subprocess, sys, hashlib

def main():
    report_path, outdir = sys.argv[1], sys.argv[2]
    excludes = []
    if '--exclude' in sys.argv:
        excludes = sys.argv[sys.argv.index('--exclude') + 1:]

    os.makedirs(outdir, exist_ok=True)
    report = json.load(open(report_path))
    jobs = []
    for item in report['install']:
        name = item['metadata']['name'].lower().replace('_', '-')
        if any(name.startswith(e) for e in excludes):
            print(f'  [跳过] {name}')
            continue
        url = item['download_info']['url']
        # PyPI 官方 CDN 在部分网络下极慢且易断，换用阿里云镜像（路径兼容）
        if 'files.pythonhosted.org/packages/' in url:
            url = url.replace('https://files.pythonhosted.org/packages/',
                              'https://mirrors.aliyun.com/pypi/packages/')
        fn = url.split('/')[-1].split('#')[0]
        sha = None
        h = item['download_info'].get('archive_info', {}).get('hash')
        if h and h.startswith('sha256='):
            sha = h.split('=', 1)[1]
        jobs.append((fn, url, sha))

    print(f'共 {len(jobs)} 个 wheel 待下载 -> {outdir}')
    round_no = 0
    while True:
        round_no += 1
        pending = []
        for fn, url, sha in jobs:
            dst = os.path.join(outdir, fn)
            if os.path.exists(dst) and sha:
                d = hashlib.sha256(open(dst, 'rb').read()).digest().hex()
                if d == sha:
                    continue
                os.remove(dst)
            pending.append((fn, url))
        if not pending:
            print('全部下载完成且校验通过 ✔')
            return 0
        print(f'第 {round_no} 轮，剩余 {len(pending)} 个...')
        for fn, url in pending:
            dst = os.path.join(outdir, fn)
            r = subprocess.run(['curl', '-fL', '--retry', '3', '--retry-delay', '2',
                                '--connect-timeout', '30', '--max-time', '1800',
                                '-C', '-', '-o', dst, url])
            tag = 'OK ' if r.returncode == 0 else f'ERR({r.returncode})'
            print(f'  [{tag}] {fn}')
        if round_no >= 12:
            print('重试轮次过多，仍有失败项 ✘')
            return 1

if __name__ == '__main__':
    sys.exit(main())
