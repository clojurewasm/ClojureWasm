import java.util.ArrayList;

public class Bench {
    public static void main(String[] args) {
        int n = 10000;
        ArrayList<Long> vec = new ArrayList<>();
        for (int i = 0; i < n; i++) vec.add((long) i);

        long sum = 0;
        for (int i = 0; i < n; i++) sum += vec.get(i);

        System.out.println(sum);
    }
}
