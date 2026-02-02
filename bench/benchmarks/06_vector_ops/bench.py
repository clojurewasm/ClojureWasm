n = 10000
vec = []
for i in range(n):
    vec.append(i)

s = 0
for i in range(n):
    s += vec[i]
print(s)
