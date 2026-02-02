n = 10000
vec = []
n.times { |i| vec << i }

sum = 0
n.times { |i| sum += vec[i] }
puts sum
