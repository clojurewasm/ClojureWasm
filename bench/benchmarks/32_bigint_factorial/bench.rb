f = 1
1000.times { f = (1..100).reduce(1, :*) }
puts f.to_s.length
