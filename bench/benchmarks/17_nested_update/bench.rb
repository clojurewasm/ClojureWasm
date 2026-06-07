n = 10000
m = {a: {b: {c: 0}}}
n.times { m[:a][:b][:c] += 1 }
puts m[:a][:b][:c]
