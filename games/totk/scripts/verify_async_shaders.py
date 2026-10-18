#!/usr/bin/env python3
"""Observe the actual packaged app with an isolated empty profile and cache.

Never controls a user's running game. Stop control on real input/preemption.
Screenshots require visual review; driver caches are deliberately not cleared.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent / 'dev'))

class UserTakeover(RuntimeError):
    pass


class SessionMonitor:
    def __init__(self, log, prior_inode, slot):
        self.log, self.prior_inode, self.slot = log, prior_inode, slot
        self.text, self.taken = '', False

    def refresh(self):
        if self.slot.preempted:
            self.taken = True
            raise UserTakeover('user launch preempted the test; control stopped')
        # Read the same file whose inode was inspected. At cleanup, inability
        # to read current state must not be treated as permission to close.
        with self.log.open(encoding='utf-8', errors='replace') as stream:
            if os.fstat(stream.fileno()).st_ino == self.prior_inode:
                raise FileNotFoundError('this session has not published its log yet')
            self.text = stream.read()
        if '[input] user input' in self.text:
            self.taken = True
            raise UserTakeover('real user input; control stopped and test game left open')
        if self.slot.preempted:  # preemption may arrive during the log read
            self.taken = True
            raise UserTakeover('user launch preempted the test; control stopped')

    def check(self, game):
        try:
            self.refresh()
        except FileNotFoundError:
            pass  # the launcher may not have created its log yet
        if game.poll() is not None:
            raise RuntimeError('game exited: '+str(game.returncode))
        if 'FATAL' in self.text or '[async-shaders] pipeline FAILED' in self.text:
            raise RuntimeError('shader/runtime failure; inspect game.log')


def finish_trial(out, commands, game, monitor, report):
    (out/'game.log').write_text(monitor.text)
    if not monitor.taken and game.poll() is None:
        try:
            with commands.open('a') as stream:
                # Refresh AFTER evidence/file I/O and directly before sending
                # close, rather than relying on the last observation-loop poll.
                monitor.refresh()
                stream.write('close\n')
            game.wait(timeout=30)
        except UserTakeover as error:
            report.update(status='interrupted', error=str(error))
        except (OSError, subprocess.TimeoutExpired) as error:
            report.update(status='failed', close_error=str(error)+'; left open')
    if monitor.taken:
        report.update(status='interrupted')
    (out/'game.log').write_text(monitor.text)
    report['exit_code'] = game.poll()


def main():
    from game_slot import GameSlot
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--async-mode', choices=('0', '1'), default='1')
    parser.add_argument('--timeout', type=float, default=300)
    args = parser.parse_args()
    out = args.output.expanduser().resolve()
    out.mkdir(parents=True, exist_ok=False)
    profile, cache, commands = out/'profile', out/'cache', out/'input.txt'
    profile.mkdir(); commands.write_text('')
    data = Path.home()/'Library/Application Support/MacNativeGames/TOTK'
    os.environ['TOTK_GAME_SLOT_DIR'] = str(data/'game-slot')
    log = Path.home()/'Library/Logs/MacNativeGames/totk.log'
    prior_inode = log.stat().st_ino if log.exists() else None
    binary = args.app/'Contents/Resources/totk/build/totk-native'
    report = dict(status='running', async_mode=args.async_mode, profile=str(profile),
                  cache=str(cache), runtime_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  scope='empty-profile startup, not long gameplay or a cold driver-cache timing test')
    def save():
        (out/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    env = os.environ | dict(TOTK_PROFILE_DIR=str(profile), TOTK_SHADER_CACHE=str(cache),
        TOTK_INPUT_FILE=str(commands), TOTK_ASSUME_FOCUS='1', TOTK_WINDOW_SIZE='1280x720',
        TOTK_ASYNC_SHADERS=args.async_mode, TOTK_SHADER_SEED='on', TOTK_MFX_INTERP='0')
    for key in ('TOTK_AUTOLOAD', 'TOTK_INPUT_SCRIPT', 'DM_PSO_MANIFEST', 'TOTK_HEADLESS'):
        env.pop(key, None)
    save()
    with GameSlot(owner='codex', purpose='async shader option verification', expect_seconds=int(args.timeout+30)) as slot:
        with (out/'launcher.log').open('wb') as stream:
            game = slot.popen([str(args.app/'Contents/MacOS/TOTK')], env=env, stdout=stream, stderr=subprocess.STDOUT)
        monitor = SessionMonitor(log, prior_inode, slot)
        try:
            first = None; deadline = time.monotonic()+args.timeout
            while time.monotonic() < deadline:
                monitor.check(game)
                if 'first presented frame' in monitor.text:
                    first = first or time.monotonic()
                    if time.monotonic()-first >= 45:
                        break
                time.sleep(.25)
            else:
                raise RuntimeError('first frame / observation timed out')
            if args.async_mode == '1':
                required = ('[async-shaders] startup warm-up continues', '[async-shaders] pending', '[async-shaders] pipeline ready:')
            else:
                required = ('启动关键管线已就绪：',)
            if any(message not in monitor.text for message in required):
                raise RuntimeError('required paths not covered: '+repr(required))
            with commands.open('a') as f:
                monitor.check(game)
                f.write('wshot '+str(out/'game.png')+'\n')
            deadline = time.monotonic()+15
            while not (out/'game.png').exists() and time.monotonic()<deadline:
                monitor.check(game); time.sleep(.25)
            monitor.check(game)
            if not (out/'game.png').exists(): raise RuntimeError('window screenshot did not complete')
            report.update(status='pass', screenshot='game.png', visual_review='pending',
                          pipeline_ready_lines=monitor.text.count('[async-shaders] pipeline ready:'))
        except Exception as error:
            report.update(status='interrupted' if monitor.taken else 'failed', error=str(error))
        finally:
            finish_trial(out, commands, game, monitor, report)
            save()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['status']=='pass' else 1


if __name__ == '__main__':
    raise SystemExit(main())
