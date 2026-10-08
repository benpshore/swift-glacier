fn greeting() -> String {
    String::from("Hello from swift-glacier!")
}

fn main() {
    println!("{}", greeting());
}

#[cfg(test)]
mod tests {
    use super::greeting;

    #[test]
    fn greets() {
        assert!(greeting().contains("swift-glacier"));
    }
}
