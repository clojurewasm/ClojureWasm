def tak(x, y, z)
  return z if x <= y
  tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y))
end

puts tak(18, 12, 6)
