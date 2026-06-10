import java.util.Arrays;

public class Bench {
    public static void main(String[] args) {
        int n = 5000;
        long total = 0;
        for (int it = 0; it < 5; it++) {
            int[] v = new int[n];
            for (int i = 0; i < n; i++) v[i] = n - i;
            Arrays.sort(v);
            long s = 0;
            for (int i = 0; i < 100; i++) s += v[i];
            total = s;
        }
        System.out.println(total);
    }
}
