total = 0
5.times do
  v = (1..5000).to_a.reverse
  v.sort!
  total = v.first(100).sum
end
puts total
