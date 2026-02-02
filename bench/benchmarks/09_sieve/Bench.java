public class Bench {
    public static void main(String[] args) {
        int limit = 1000;
        boolean[] sieve = new boolean[limit + 1];
        for (int i = 2; i <= limit; i++) sieve[i] = true;

        for (int i = 2; i * i <= limit; i++) {
            if (sieve[i]) {
                for (int j = i * i; j <= limit; j += i)
                    sieve[j] = false;
            }
        }

        int count = 0;
        for (int i = 2; i <= limit; i++) {
            if (sieve[i]) count++;
        }
        System.out.println(count);
    }
}
