## 0.0.23

- Add Docker, `$*docker`, `$*docker-cli` (WIP)
- Add -s/--mount-docker-socket switches to mount /var/run/docker.sock
  if running script inside a container.
- Add `$*curl`
- Add File.move-to
- POSIX OS has been removed
- Linux OS has been added
- `("foo:$_" if $foo)` now reduces down to `${foo:+"foo:$foo"}`
- `$*interactive` now defaults to False
  - -i cli switch to set `$*interactive` to `$?IN.tty`
  - -I cli switch to force `$*interactive` to `True`

## 0.0.22

- CLI overhauled. See spit --help.
- option expression prefix changed from '->' to just ':'. You can now
  escape it with a \: if you want to start with a literal ':'

## 0.0.21

- Add File.mkdir
- Add File.cd
- Add a :dir option to File.tmp to create a tmp directory.
- Add spit-dev command in root of src to be used instead of ./bin/spit
  for development.
- Renamed $$ to $?PID
- Renamed File.create to File.touch
- Renamed File.child to File.add
- Routines that just do concatenation can now be inlined

## 0.0.20

- FD.next-free now uses /proc to figure out what FD is free.
- Fixed bug where `>` type comparisons would fail if both sides were
  know at compile time.


## 0.0.19

- File.read renamed to File.slurp
- Type blessing syantax changed from File{"foo"} to File("foo")
- Add GitHubRepo which represents a guthub repo owner/repo-name like
  `GitHubRepo<spitsh/spitsh>`
- Add GitURL, which represents `git clone`'able string like
  `GitURL<https://github.com/spitsh/spitsh.git/>`
- Add $*git, which gives you the git command
- Add &prompt which prompts the user with a string and returns their answer as a Bool
- Add $?IN, basically just FD(0)
- Add File.find which is an interface to find(1)
- Add PID.kill which sends a signal to a process
- Add &sleep, a wrapper around sleep(1)
- Add env declarator to reserve shell environment variable names. Used like:
  ```perl6
    env $MY_ENV_VAR;
    #or
    env $MY_ENV_VAR = "foo";
  ```

## 0.0.18
- Regex system redesigned and re-implemented
  - regex parsing is now done during the parse phase (no more 2-pass parsing)
  - The compiler now has the responsibility of inserting
    interpolations into the regex pattern that is eventually chosen

- Add PID class which is a blessed int representing a process ID
- Add $?PID which holds the PID for the main script
- Add $$ which gives access to the shell's $$
- spit eval now reads from STDIN if it doesn' have an argument


## 0.0.17
- add Str.matches which is like .match but doesn't set `@/`.
- ~~ and ACCEPTS have been overhauled. Classes now can have their own
  .ACCEPTS method which controls what ~~ returns.
- `SPIT_SETTING_DEV=1` can be set when you are working on core code to
  recompile the SETTING after you make changes.

## 0.0.16

- Precompilation of CORE setting and core modules. Compilation is much faster now.


## 0.0.15

- new .NAME meta-method which returns the name of a variable
  `$a.NAME` -> "a" or "a_1" etc
- Better inlining of blocks all around
- Reworked FD after investigating how `exec(1)` actually works:
  - .open-w and .open-r been removed. They
  both did the same thing. They are replaced with .dup which AFAICT is
  what exec is actually doing when you use it with two file descriptors
  - open-file-w/open-file-r has been renamed to open-w and open-r
  - open-rw has been added
  - writable has been renamed to is-open which is what it actually does.
- Added FD.get and FD.getc (which isn't working on Debian/dash yet)

## 0.0.14

- `$?` variable representing the exit status of the last command
  executed.
- You can now have multiple statements inside `(...)`. E.g.
  ```perl6
  say ( say 'inside goes first!'; "the will print second");
  ```
  This is especially useful in conditionals
  ```perl6
  my $str = '';
  my @a =  ^100;
  my $i = 0;
  $i++ while ($str ~= @a[$i]; $str.chars < 20);
  say $str;
  ```
- `.match` now retruns a `Bool` and sets the new `@/` variable with the matches.
  ```perl6
  my $regex = rx‘^(.+)://([^/]+)/?(.*)$’;
  if 'https://github.com/spitsh/spitsh'.match($regex) {
      .say for @/;
  }
  ```

## 0.0.13

- Added inline on blocks
```perl6
constant $foo = on {
    Debian { 'debian' }
    RHEL   { 'redhat'  }
};
```

## 0.0.12

- Fixed lots of String escaping bugs
- Added `rx{...}` Perl 6 like regex quote
- BusyBox is now its own OS
- Add Str.match, which matches against a regex and returns the match
  and any capture groups. This is very much a WIP, but this at least
  proves it's possible to return regex capture groups separately
  **without** using perl.
- add `.=` operator which works for calling methods and commands like:
  - `my File $tmp .= tmp;`
  - `my $foo = "foo"; $foo .= ${ sed "s/o/e/" };`

## 0.0.11

- for and while loops can be used as values like
  ```perl6
  my @a = for <one two three> { .uc }
  say @a eq <ONE TWO THREE> #-> True
  ```

## 0.0.10

- Added experimental .PRIMITIVE which returns the primitive type of the node
- Parameterized class comparisons `List[File] ~~ List[Str]` now give
  correct answer (True)
- if statements are now non-itemizing when used as a
  value. i.e. `${echo ("foo" if False)}` passes 0 arguments to echo
- Hugely improved error messages esp for "missing '}'" type syntax
  errors. They are still a WIP though.

## 0.0.9

- `when` now works even where $_ hasn't been declared
- A lot better inlining of if statements.
- You can now assign to control statements without putting them in ()
- Made variables in "" a bit smarter. It only uses ${curlies} when it needs to now.


## 0.0.8

- Great itemization refactor
  - `|` slip prefix is no longer a thing
  - Instead you have `@$foo` and `@(...)` to flatten things
  - `$@foo` and `$(...)` to itemize things
  - This is only relevant to `${...}` calls and `for` loops arguments
    for now as call arguments are always itemized.
  - `@self` now flattens right. It's still very experimental and is
    going to change a lot soon. I might make it so it's only available
    if your class inherits from List.
- lists as a single call argument is fixed. `foo(<one two three>)` used
  to be three arguments. Now it's one.

## 0.0.7

- Completely changed command syntax again. It's now much more terse.
  `${yum 'install','-y',$self ::>X}` => `${yum install -y $self *>X}`
  - commas removed
  - just `>` instead of `:>`
  - barewords instead of quoting on anything ~~ /[\w|'-']+/

## 0.0.6

- Added CHANGELOG.md ^_^
- `self` becomes `$self` and `@self` (no difference between the two yet)
- static methods must be labeled static like `static method foo() { ... }`
