#pragma once
#include <cstdint>
#include <unordered_map>
#include <chrono>

enum class GestureType {
	TAP,
	DRAG,
	LONG_PRESS,
	SCROLL,
	PINCH
};

struct TouchPoint {
	int id;
	float x;
	float y;
	bool active;
};

struct InputSink {
	virtual ~InputSink() = default;
	virtual void onGesture(GestureType) = 0;
	virtual void onClick(int button) = 0;
	virtual void onDrag(float dx, float dy) = 0;
	virtual void onScroll(float dx, float dy) = 0;
	virtual void onZoom(float scale) = 0;
};

class GestureArbiter {
public:
	enum class State {
		IDLE,
		TAP_DRAG_SCROLL,
		LONG_PRESS,
		PINCH
	};

	struct Contact {
		float startX;
		float startY;
		float lastX;
		float lastY;
		std::chrono::steady_clock::time_point startTime;
	};

	GestureArbiter(float tapThresholdVp = 8.0f, std::chrono::milliseconds longPress = std::chrono::milliseconds(500))
		: tapThresholdVp_(tapThresholdVp), longPress_(longPress) {}

	void beginTouch(int id, float x, float y, float density);
	void moveTouch(int id, float x, float y);
	void endTouch(int id);
	void cancelAll();
	void setMousePresent(bool present) { mousePresent_ = present; }
	bool isMousePresent() const { return mousePresent_; }

	std::unordered_map<int, Contact> &contacts() { return contacts_; }
	const std::unordered_map<int, Contact> &contacts() const { return contacts_; }
	State state() const { return state_; }
	void setState(State s) { state_ = s; }
	float tapThresholdVp() const { return tapThresholdVp_; }
	std::chrono::milliseconds longPress() const { return longPress_; }

private:
	float tapThresholdVp_;
	std::chrono::milliseconds longPress_;
	bool mousePresent_ = false;
	State state_ = State::IDLE;
	std::unordered_map<int, Contact> contacts_;
};

/* Shared arbiter + free helpers, used by dispatchTouch(). */
void setMousePresent(bool present);
void cancelAllTouch();
void dispatchTouch(TouchPoint *pts, int n, InputSink *sink);