import java.util.concurrent.atomic.AtomicLong;

public class Bench {
    public static void main(String[] args) {
        int n = 10000;
        AtomicLong counter = new AtomicLong(0);
        for (int i = 0; i < n; i++) {
            counter.set(counter.get() + 1);
        }
        System.out.println(counter.get());
    }
}
