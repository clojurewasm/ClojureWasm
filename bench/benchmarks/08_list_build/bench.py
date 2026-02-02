from collections import deque

n = 10000
lst = deque()
for i in range(n):
    lst.appendleft(i)
print(len(lst))
