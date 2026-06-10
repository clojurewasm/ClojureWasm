import re
p = re.compile(r'\d+')
s = "a12b345c6789d0e"
c = 0
for _ in range(10000):
    c = len(p.findall(s))
print(c)
