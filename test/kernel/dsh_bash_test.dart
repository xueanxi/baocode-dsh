import 'package:baocode/kernel/dsh/dsh_bash.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Where the Git for Windows bash dsh's `dsh-gitbash-shell` plugin runs is
/// found: each of the places it may be, in order, and the machine that has
/// none. Nothing here reads the disk or runs git: [exists] and [gitExecPath]
/// are given, so the machine that runs the tests decides nothing.
void main() {
  /// A Git for Windows install, and the folder `git --exec-path` names in it.
  const git = 'C:/Program Files/Git';
  const bash = '$git/bin/bash.exe';
  const execPath = '$git/mingw64/libexec/git-core';

  /// Says only the paths in [there] exist, whichever separator they are
  /// written with.
  bool Function(String path) installed(Set<String> there) {
    final wanted = {for (final path in there) p.normalize(path)};
    return (path) => wanted.contains(p.normalize(path));
  }

  /// The environment of a login shell with [path] on its PATH.
  Map<String, String> shell({String path = r'C:\Windows\System32'}) => {
    'PATH': path,
  };

  test('BAOCODE_GIT_BASH is the one it names', () async {
    const named = r'D:\tools\git\bin\bash.exe';
    expect(
      await findGitBash(
        environment: {...shell(), 'BAOCODE_GIT_BASH': named},
        exists: installed({named}),
        // Said and there: neither the PATH nor git is asked.
        gitExecPath: (_) async => fail('git was run'),
        windows: true,
      ),
      p.normalize(named),
    );
  });

  test(
    'else the bash on the login shell PATH, the first that is there',
    () async {
      // A PATH entry without bash in it first: the one that is there is taken,
      // whatever its place.
      const onPath = r'D:\Git\usr\bin\bash.exe';
      expect(
        await findGitBash(
          environment: shell(path: r'C:\Windows;D:\Git\usr\bin;D:\Git\bin'),
          exists: installed({onPath}),
          gitExecPath: (_) async => execPath,
          windows: true,
        ),
        p.normalize(onPath),
      );
    },
  );

  test('the PATH names WSL\'s bash first: the next one is taken', () async {
    // Windows 10's own `bash`, a WSL Linux shell, sits in System32 — ahead of
    // Git on a login shell's PATH. Handed a Windows path, it reads it as a
    // Linux one, so it is passed over for the Git's bash below it.
    const wsl = r'C:\Windows\System32\bash.exe';
    const gitBash = r'D:\Git\bin\bash.exe';
    expect(
      await findGitBash(
        environment: shell(path: r'C:\Windows\System32;D:\Git\bin'),
        exists: installed({wsl, gitBash}),
        // Passed over, not asked about.
        gitExecPath: (_) async => fail('git was run'),
        windows: true,
      ),
      p.normalize(gitBash),
    );
  });

  test('the WindowsApps alias is passed over too', () async {
    const alias = r'C:\Users\me\AppData\Local\Microsoft\WindowsApps\bash.exe';
    const gitBash = r'D:\Git\bin\bash.exe';
    expect(
      await findGitBash(
        environment: shell(
          path:
              r'C:\Users\me\AppData\Local\Microsoft\WindowsApps;'
              r'D:\Git\bin',
        ),
        exists: installed({alias, gitBash}),
        gitExecPath: (_) async => fail('git was run'),
        windows: true,
      ),
      p.normalize(gitBash),
    );
  });

  test('nothing but Windows\' own bash: null', () async {
    // Both of Windows' own bashes are there, and neither is Git's: what is
    // left is the Git of an install, and this machine has none.
    const wsl = r'C:\Windows\System32\bash.exe';
    const alias = r'C:\Users\me\AppData\Local\Microsoft\WindowsApps\bash.exe';
    expect(
      await findGitBash(
        environment: shell(
          path:
              r'C:\Windows\System32;'
              r'C:\Users\me\AppData\Local\Microsoft\WindowsApps',
        ),
        exists: installed({wsl, alias}),
        gitExecPath: (_) async => null,
        windows: true,
      ),
      isNull,
    );
  });

  test('else the bash of the Git that `git --exec-path` belongs to', () async {
    // `git --exec-path` prints a folder inside the install, with its line
    // ending as git leaves it: the Git root is above it, where bash lives.
    // Asked because that PATH names a git of the install (`cmd/git.exe`).
    expect(
      await findGitBash(
        environment: shell(path: '$git/cmd'),
        exists: installed({bash, '$git/cmd/git.exe'}),
        gitExecPath: (_) async => '$execPath\n',
        windows: true,
      ),
      p.normalize(bash),
    );
  });

  test('a PATH with no git in it: git is never run', () async {
    // The one place a process is started is the `git --exec-path` step, and a
    // widget test's fake clock never lets one finish: where that PATH has no
    // git — and a PATH with none answers that step already — nothing is
    // started, and the search goes on to the installs it can look at.
    expect(
      await findGitBash(
        environment: shell(),
        exists: installed({}),
        gitExecPath: (_) async => fail('git was asked'),
        windows: true,
      ),
      isNull,
    );
  });

  test('a Git elsewhere: the one in Program Files is looked at', () async {
    const elsewhere = 'C:/Program Files (x86)/Git/bin/bash.exe';
    expect(
      await findGitBash(
        environment: shell(),
        exists: installed({elsewhere}),
        gitExecPath: (_) async => null,
        windows: true,
      ),
      p.normalize(elsewhere),
    );
  });

  test('no Git at all: null', () async {
    expect(
      await findGitBash(
        environment: shell(),
        exists: installed({}),
        // Not installed either: no exec path, and nothing in Program Files.
        gitExecPath: (_) async => null,
        windows: true,
      ),
      isNull,
    );
  });

  test('POSIX: null, bash being the shell itself', () async {
    expect(
      await findGitBash(
        environment: {'PATH': '/usr/bin'},
        exists: (_) => fail('nothing is looked for off Windows'),
        windows: false,
      ),
      isNull,
    );
  });
}
