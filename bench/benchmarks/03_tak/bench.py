import sys
sys.setrecursionlimit(100000)

def tak(x, y, z):
    if x <= y:
        return z
    return tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y))

print(tak(18, 12, 6))
