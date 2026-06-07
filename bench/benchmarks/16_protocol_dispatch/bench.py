class Computable:
    def __init__(self, factor):
        self.factor = factor
    def compute(self, x):
        return self.factor * x

n = 10000
m = Computable(3)
total = 0
for i in range(n):
    total += m.compute(i)
print(total)
