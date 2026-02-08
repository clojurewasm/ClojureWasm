def sieve(limit)
  candidates = (2..limit).to_a
  count = 0
  until candidates.empty?
    p = candidates.shift
    count += 1
    candidates.reject! { |x| x % p == 0 }
  end
  count
end

puts sieve(1000)
