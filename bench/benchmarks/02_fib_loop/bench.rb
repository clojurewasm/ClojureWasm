def fib(n)
  a, b = 0, 1
  n.times { a, b = b, a + b }
  a
end

puts fib(25)
