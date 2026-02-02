def sieve(limit)
  is_prime = Array.new(limit + 1, true)
  is_prime[0] = is_prime[1] = false
  (2..Math.sqrt(limit).to_i).each do |i|
    if is_prime[i]
      (i * i..limit).step(i) { |j| is_prime[j] = false }
    end
  end
  is_prime.count(true)
end

puts sieve(1000)
