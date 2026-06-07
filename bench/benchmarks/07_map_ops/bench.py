n = 1000
m = {}
for i in range(n):
    m[i] = i

s = 0
for i in range(n):
    s += m[i]
print(s)
