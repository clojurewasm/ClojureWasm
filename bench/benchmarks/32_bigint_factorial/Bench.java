import java.math.BigInteger;

public class Bench {
    public static void main(String[] args) {
        BigInteger f = BigInteger.ONE;
        for (int i = 0; i < 1000; i++) {
            f = BigInteger.ONE;
            for (int k = 2; k <= 100; k++) f = f.multiply(BigInteger.valueOf(k));
        }
        System.out.println(String.valueOf(f).length());
    }
}
