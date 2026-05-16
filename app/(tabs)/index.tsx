import { useState } from "react";
import { StyleSheet, Text, TextInput, View } from "react-native";

export default function Home() {
  const [search, setSearch] = useState("");
  const [result, setResult] = useState<any>(null);

  const handleSearch = (text: string) => {
    setSearch(text);

    if (text.toLowerCase().includes("guanabara")) {
      setResult({
        name: "Guanabara - Campo Grande",
        status: "🟡 Fluxo moderado",
        time: "10–15 min de espera",
        trend: "📈 aumentando",
      });
    } else {
      setResult(null);
    }
  };

  return (
    <View style={styles.container}>
      <Text style={styles.title}>GoWait</Text>

      <TextInput
        style={styles.input}
        placeholder="Pesquisar mercado..."
        value={search}
        onChangeText={handleSearch}
      />

      {result && (
        <View style={styles.card}>
          <Text style={styles.name}>{result.name}</Text>
          <Text>{result.status}</Text>
          <Text>{result.time}</Text>
          <Text>{result.trend}</Text>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 20,
    justifyContent: "center",
    backgroundColor: "#F5F5F5",
  },
  title: {
    fontSize: 32,
    fontWeight: "bold",
    marginBottom: 20,
  },
  input: {
    backgroundColor: "white",
    padding: 12,
    borderRadius: 10,
    marginBottom: 20,
  },
  card: {
    backgroundColor: "white",
    padding: 15,
    borderRadius: 10,
  },
  name: {
    fontSize: 18,
    fontWeight: "bold",
  },
});