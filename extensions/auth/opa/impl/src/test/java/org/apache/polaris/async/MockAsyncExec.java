/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
package org.apache.polaris.async;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import org.apache.polaris.ids.mocks.MutableMonotonicClock;

public class MockAsyncExec implements AsyncExec {
  private final MutableMonotonicClock clock;
  private final List<Task> tasks = new CopyOnWriteArrayList<>();

  public MockAsyncExec(MutableMonotonicClock clock) {
    this.clock = clock;
  }

  @Override
  public Cancelable<?> schedule(Runnable runnable, Duration delay) {
    Task task = new Task(runnable, clock.currentInstant().plus(delay));
    tasks.add(task);
    return () -> tasks.remove(task);
  }

  public int readyCount() {
    return readyCallables().size();
  }

  public List<Task> readyCallables() {
    Instant now = clock.currentInstant();
    List<Task> ready = new ArrayList<>();
    for (Task task : tasks) {
      if (!task.called && !task.canceled && !task.runAt.isAfter(now)) {
        ready.add(task);
      }
    }
    return ready;
  }

  public List<Task> tasks() {
    return new ArrayList<>(tasks);
  }

  @Override
  public void close() {
    tasks.clear();
  }

  public final class Task {
    private final Runnable runnable;
    private final Instant runAt;
    private boolean called;
    private boolean canceled;

    private Task(Runnable runnable, Instant runAt) {
      this.runnable = runnable;
      this.runAt = runAt;
    }

    public void call() {
      if (called || canceled) {
        return;
      }
      called = true;
      tasks.remove(this);
      runnable.run();
    }
  }
}
