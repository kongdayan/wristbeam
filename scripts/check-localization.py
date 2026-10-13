#!/usr/bin/env python3
"""Read-only source/catalog coverage check."""
from pathlib import Path
import re,json
root=Path(__file__).resolve().parent.parent
def expression_end(s,i,closing=')'):
    depth=1
    while i<len(s):
        if s[i]=='"': i,_,_=string(s,i); continue
        if s[i]=='(': depth+=1
        elif s[i]==')':
            depth-=1
            if depth==0:return i
        i+=1
    raise ValueError('unterminated interpolation')
def string(s,i):
    start=i;i+=1;out='';n=0
    while i<len(s):
        if s[i]=='"':return i+1,out,start
        if s[i]=='\\':
            if s[i+1]=='(': end=expression_end(s,i+2);out+='{'+str(n)+'}';n+=1;i=end+1;continue
            out+= {'n':'\n','r':'\r','t':'\t'}.get(s[i+1],s[i+1]);i+=2;continue
        out+=s[i];i+=1
    raise ValueError('unterminated string')
def strings(s):
    i=0
    while i<len(s):
        if s.startswith('//',i):j=s.find('\n',i);i=j if j!=-1 else len(s);continue
        if s.startswith('/*',i):j=s.find('*/',i+2);i=j+2 if j!=-1 else len(s);continue
        if s[i]=='"':i,out,start=string(s,i);yield out,start;continue
        i+=1

catalog=json.loads((root/'Sources/GarminBar/Resources/Localization/en.json').read_text())
missing=[]
for p in (root/'Sources/GarminBar').rglob('*.swift'):
    if p.name=='Localization.swift':continue
    for value,pos in strings(p.read_text()):
        if re.search('[\u4e00-\u9fff]',value) and value not in catalog:missing.append((str(p.relative_to(root)),value))
for key,value in catalog.items():
    a=set(re.findall(r'\{[0-9]+\}',key));b=set(re.findall(r'\{[0-9]+\}',value))
    if a!=b:missing.append(('placeholder mismatch',key))
if missing:
    for file,key in missing:print(file,repr(key))
    raise SystemExit(1)
print(f'PASS: {len(catalog)} localization keys; source coverage and placeholders')
