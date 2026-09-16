from pathlib import Path
import subprocess
import argparse
parser=argparse.ArgumentParser(description='Create isolated repositories for Diff GUI cases')
parser.add_argument('directory', type=Path)
root=parser.parse_args().directory
root.mkdir(parents=True, exist_ok=True)
def git(p,*args):return subprocess.check_output(['git','-C',str(p),*args],stderr=subprocess.STDOUT).decode().strip()
def init(name):
 p=root/name;p.mkdir();git(p,'init','-b','main');git(p,'config','user.name','Diff QA');git(p,'config','user.email','diff-qa@example.test');return p
p=init('review-fixture')
(p/'Demo.swift').write_text('import Foundation\n\nstruct Greeting {\n    let name = "base"\n    func text() -> String {\n        return "Hello " + name\n    }\n}\n')
(p/'delete.txt').write_text('delete me\n');(p/'rename.txt').write_text('rename me\n');(p/'mode.sh').write_text('#!/bin/sh\necho ready\n');(p/'unchanged.txt').write_text('base\n')
git(p,'add','.');git(p,'commit','-m','fixture baseline');git(p,'switch','-c','feature/review')
(p/'committed.txt').write_text('branch contribution\n');git(p,'add','committed.txt');git(p,'commit','-m','feature contribution')
git(p,'switch','main');(p/'target-only.txt').write_text('target change\n');git(p,'add','target-only.txt');git(p,'commit','-m','target contribution');git(p,'switch','feature/review')
s=(p/'Demo.swift').read_text().replace('"base"','"staged"');(p/'Demo.swift').write_text(s);git(p,'add','Demo.swift');(p/'Demo.swift').write_text(s.replace('"staged"','"working"'))
git(p,'mv','rename.txt','renamed file.txt');(p/'delete.txt').unlink();(p/'mode.sh').chmod(0o755)
(p/'new file.txt').write_text('untracked content\n');(p/'binary.dat').write_bytes(b'\0\x01\xff');(p/'large.txt').write_text('x'*1000001);(p/'link.txt').symlink_to('Demo.swift');(p/'empty.txt').write_text('')
(p/'odd\tname.txt').write_text('<script>window.test=1</script>\n')
q=init('clean-fixture');(q/'clean.txt').write_text('clean\n');git(q,'add','.');git(q,'commit','-m','clean baseline')
u=init('unborn-fixture');(u/'first.txt').write_text('first file\n')
b=init('no-base-fixture');git(b,'branch','-m','topic');(b/'one.txt').write_text('one\n');git(b,'add','.');git(b,'commit','-m','root')
c=init('conflict-fixture');(c/'conflict.txt').write_text('base\n');git(c,'add','.');git(c,'commit','-m','base');git(c,'switch','-c','topic');(c/'conflict.txt').write_text('topic\n');git(c,'commit','-am','topic');git(c,'switch','main');(c/'conflict.txt').write_text('main\n');git(c,'commit','-am','main');subprocess.run(['git','-C',str(c),'merge','topic'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
print(root)
