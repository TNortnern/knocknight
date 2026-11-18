"""CRLF-safe exact-string patcher: python -I tools/patch.py <file> <old_file> <new_file>  (old/new given as files with LF text)"""
import sys
def patch(path, old, new, count=1):
    s = open(path, newline='').read()
    crlf = '\r\n' in s
    if crlf:
        old = old.replace('\r\n', '\n').replace('\n', '\r\n'); new = new.replace('\r\n', '\n').replace('\n', '\r\n')
    if s.count(old) != count:
        raise SystemExit(f"patch: {path}: expected {count} match(es), found {s.count(old)} for:\n{old[:200]}")
    open(path, 'w', newline='').write(s.replace(old, new))
if __name__ == '__main__':
    patch(sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read())
