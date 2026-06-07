import java.util.ArrayList;

/* Filter-based sieve: match Clojure's functional approach */
public class Bench {
    public static void main(String[] args) {
        int limit = 1000;
        ArrayList<Integer> candidates = new ArrayList<>();
        for (int i = 2; i <= limit; i++) candidates.add(i);

        int count = 0;
        while (!candidates.isEmpty()) {
            int p = candidates.remove(0);
            count++;
            final int prime = p;
            candidates.removeIf(x -> x % prime == 0);
        }
        System.out.println(count);
    }
}
