class Node:
    __slots__ = ('val', 'next')
    def __init__(self, val, next_node=None):
        self.val = val
        self.next = next_node

n = 10000
head = None
for i in range(n):
    head = Node(i, head)

count = 0
cur = head
while cur is not None:
    count += 1
    cur = cur.next
print(count)
