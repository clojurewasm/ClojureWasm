s = "a12b345c6789d0e"
c = 0
10000.times { c = s.scan(/\d+/).length }
puts c
