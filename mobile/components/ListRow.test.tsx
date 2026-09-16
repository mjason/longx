import { fireEvent, render, screen } from "@testing-library/react-native";
import { ListRow } from "./ListRow";

test("a row shows its title and subtitle and reacts to a press", async () => {
  const onPress = jest.fn();
  await render(<ListRow title="jbt_lab" subtitle="/home/mj/dev/python/jbt_lab" onPress={onPress} testID="row" />);
  expect(screen.getByText("jbt_lab")).toBeTruthy();
  await fireEvent.press(screen.getByTestId("row"));
  expect(onPress).toHaveBeenCalled();
});
