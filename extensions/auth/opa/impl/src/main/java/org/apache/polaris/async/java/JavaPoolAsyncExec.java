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
package org.apache.polaris.async.java;

import jakarta.enterprise.context.ApplicationScoped;
import java.time.Duration;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import org.apache.polaris.async.AsyncExec;
import org.apache.polaris.async.Cancelable;

@ApplicationScoped
public class JavaPoolAsyncExec implements AsyncExec {
  private final ScheduledExecutorService executorService =
      Executors.newSingleThreadScheduledExecutor(
          runnable -> {
            Thread thread = new Thread(runnable, "polaris-opa-async-exec");
            thread.setDaemon(true);
            return thread;
          });

  @Override
  public Cancelable<?> schedule(Runnable runnable, Duration delay) {
    long delayMs = Math.max(0L, delay.toMillis());
    ScheduledFuture<?> future = executorService.schedule(runnable, delayMs, TimeUnit.MILLISECONDS);
    return () -> future.cancel(false);
  }

  @Override
  public void close() {
    executorService.shutdownNow();
  }
}
