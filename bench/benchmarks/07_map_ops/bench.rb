n = 1000
m = {}
n.times { |i| m[i] = i }

sum = 0
n.times { |i| sum += m[i] }
puts sum
